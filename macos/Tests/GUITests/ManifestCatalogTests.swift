import XCTest
@testable import DeskBoxGUI

/// M50：Manifests 面板的数据与菜单栏弹窗的操作。
final class ManifestCatalogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-manifests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func manifest(kernel: String = "vmlinuz-virt", signed: Bool = true, extraAsset: String? = nil) -> String {
        var digests = "\"\(kernel)\":\"aa\",\"initrd-deskbox.img\":\"bb\",\"root-disk.raw\":\"cc\""
        if let extraAsset { digests += ",\"\(extraAsset)\":\"dd\"" }
        let signature = signed ? ",\"signature\":{\"alg\":\"ed25519\",\"keyID\":\"d75fa8c9ad434947\",\"sig\":\"x\"}" : ""
        return "{\"fileDigests\":{\(digests)},\"guestAssetVersion\":3,\"kernelURL\":\"\(kernel)\",\"initrdURL\":\"initrd-deskbox.img\",\"rootDiskURL\":\"root-disk.raw\"\(signature)}"
    }

    private func addAssets(_ names: [String] = ["vmlinuz-virt", "initrd-deskbox.img", "root-disk.raw"]) throws {
        for name in names { try write(name, "x") }
    }

    func testFileNameFilter() {
        for yes in ["manifest.json", "manifest-gpu.json", "manifest-copy.json", "manifest.v2.json"] {
            XCTAssertTrue(ManifestCatalog.isManifestFileName(yes), yes)
        }
        for no in ["manifest.unsigned.json", "manifest-gpu.unsigned.json", "sbom.json", "release-keys.json",
                   "manifest.json.bak", "my-manifest.json", "manifest", ".manifest.json"] {
            XCTAssertFalse(ManifestCatalog.isManifestFileName(no), no)
        }
    }

    func testSignedManifestWithAllAssetsIsReady() throws {
        try addAssets()
        try write("manifest.json", manifest())
        let rows = ManifestCatalog.scan(directory: dir)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "manifest.json")
        XCTAssertEqual(rows[0].status, .ready)
        XCTAssertTrue(rows[0].isRunnable)
        XCTAssertEqual(rows[0].keyID, "d75fa8c9ad434947")
        XCTAssertEqual(rows[0].signatureText, "d75fa8c9ad434947", "回归：这一列此前永远是 -")
        XCTAssertEqual(rows[0].kernel, "vmlinuz-virt")
        XCTAssertEqual(rows[0].assetVersion, 3)
        XCTAssertEqual(rows[0].statusText, "signed")
        XCTAssertEqual(rows[0].path, dir.appendingPathComponent("manifest.json").path)
        XCTAssertGreaterThan(rows[0].sizeBytes, 0)
    }

    func testUnsignedManifestIsListedAndRunnableButMarked() throws {
        try addAssets()
        try write("manifest-dev.json", manifest(signed: false))
        let row = try XCTUnwrap(ManifestCatalog.scan(directory: dir).first)
        XCTAssertEqual(row.status, .unsigned)
        XCTAssertTrue(row.isRunnable, "是否放行未签名由 daemon 决定")
        XCTAssertEqual(row.signatureText, "-")
    }

    func testMissingAssetsAreNamedAndNotRunnable() throws {
        try addAssets(["vmlinuz-virt"])
        try write("manifest.json", manifest())
        let row = try XCTUnwrap(ManifestCatalog.scan(directory: dir).first)
        XCTAssertEqual(row.status, .missingAssets(["initrd-deskbox.img", "root-disk.raw"]))
        XCTAssertFalse(row.isRunnable)
        XCTAssertEqual(row.statusText, "missing: initrd-deskbox.img, root-disk.raw")
        XCTAssertEqual(row.keyID, "d75fa8c9ad434947", "缺资产不影响显示它是谁签的")
    }

    func testAssetNamesWithPathSeparatorsNeverCountAsPresent() throws {
        try addAssets()
        try write("outside.bin", "x")
        try write("manifest.json", manifest(extraAsset: "../\(dir.lastPathComponent)/outside.bin"))
        let row = try XCTUnwrap(ManifestCatalog.scan(directory: dir).first)
        guard case .missingAssets(let names) = row.status else { return XCTFail("\(row.status)") }
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].contains("/"))
        XCTAssertFalse(row.isRunnable)
    }

    func testUnreadableFiles() throws {
        try write("manifest-bad.json", "{not json")
        try write("manifest-other.json", "{\"hello\":1}")
        try write("manifest-array.json", "[1,2]")
        try Data(count: 1_100_000).write(to: dir.appendingPathComponent("manifest-huge.json"))
        let rows = ManifestCatalog.scan(directory: dir)
        XCTAssertEqual(rows.map(\.name), ["manifest-array.json", "manifest-bad.json", "manifest-huge.json", "manifest-other.json"])
        XCTAssertEqual(rows.map(\.status), [.unreadable("not JSON"), .unreadable("not JSON"), .unreadable("too large"), .unreadable("not a manifest")])
        XCTAssertTrue(rows.allSatisfy { !$0.isRunnable && $0.signatureText == "-" })
    }

    func testScanIsSortedSkipsUnsignedIntermediatesAndSurvivesMissingDirectory() throws {
        try addAssets(["vmlinuz-virt", "vmlinuz-virt-gpu", "initrd-deskbox.img", "root-disk.raw"])
        try write("manifest.json", manifest())
        try write("manifest-gpu.json", manifest(kernel: "vmlinuz-virt-gpu"))
        try write("manifest.unsigned.json", manifest(signed: false))
        try write("sbom.json", "{}")
        let rows = ManifestCatalog.scan(directory: dir)
        XCTAssertEqual(rows.map(\.name), ["manifest-gpu.json", "manifest.json"])
        XCTAssertEqual(rows.map(\.kernel), ["vmlinuz-virt-gpu", "vmlinuz-virt"])
        XCTAssertEqual(ManifestCatalog.scan(directory: dir.appendingPathComponent("nope")), [])
    }

    // MARK: 菜单栏弹窗

    func testMenuBarActionsFollowTheSameStateRules() {
        XCTAssertEqual(MenuBarSandboxActions.available(forState: "running"), [.restart, .stop, .rm])
        XCTAssertEqual(MenuBarSandboxActions.available(forState: "suspended"), [.resume, .rm])
        XCTAssertEqual(MenuBarSandboxActions.available(forState: "failed"), [.restart, .rm])
        for state in ["pending", "suspending", "resuming", "stopping", "stopped", "garbage", ""] {
            XCTAssertEqual(MenuBarSandboxActions.available(forState: state), [.rm], state)
        }
    }

    func testMenuBarNeverOffersPanelActionsOrStopWhereItWouldBeRejected() {
        for state in ["pending", "running", "suspending", "suspended", "resuming", "stopping", "stopped", "failed"] {
            let actions = MenuBarSandboxActions.available(forState: state)
            for panelAction in [SandboxAction.terminal, .console, .exec, .suspend] {
                XCTAssertFalse(actions.contains(panelAction), "\(state): \(panelAction.rawValue)")
            }
            // 回归：此前任何状态都有 stop。
            if state != "running" { XCTAssertFalse(actions.contains(.stop), state) }
            XCTAssertTrue(actions.contains(.rm), state)
            // 弹窗里的每个操作都能构造出 daemon 请求。
            for action in actions { XCTAssertNotNil(SandboxRowActions.request(for: action, sandboxId: "SB"), action.rawValue) }
        }
    }
}
