import Foundation
import XCTest
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M23 / INV-02：不同凭据域不共享 guest kernel。
///
/// 这里覆盖**可证伪的强制点**：域解析 fail-closed、COW 跨域拒绝、快照 AAD 绑定域、
/// 以及「域 × 工作区 × grant 组合」的属性矩阵。
final class CredentialDomainTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-domain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - 域 ID 与解析

    func testDomainIDValidation() {
        XCTAssertTrue(CredentialDomainID("personal").isValid)
        XCTAssertTrue(CredentialDomainID("work-2024_x").isValid)
        for bad in ["", "Personal", "a b", "../etc", "a/b", String(repeating: "a", count: 33)] {
            XCTAssertFalse(CredentialDomainID(bad).isValid, "should reject '\(bad)'")
        }
    }

    func testRegistryParsesAndResolves() throws {
        let registry = try writeRegistry([
            CredentialDomain(domainID: CredentialDomainID("personal")),
            CredentialDomain(domainID: CredentialDomainID("work"),
                             brokerPolicyFile: "broker-policy.work.json",
                             brokerCredentialsFile: "broker-credentials.work.local")
        ], defaultDomain: "personal")
        XCTAssertEqual(try registry.resolve(CredentialDomainID("work")).domainID.raw, "work")
        // nil → defaultDomain（只在创建路径使用）
        XCTAssertEqual(try registry.resolve(nil).domainID.raw, "personal")
        // 未知域必须拒绝
        XCTAssertThrowsError(try registry.resolve(CredentialDomainID("nope"))) { error in
            guard case DomainResolutionError.unknownDomain = error else {
                return XCTFail("unexpected: \(error)")
            }
            XCTAssertEqual((error as? DomainResolutionError)?.reasonCode, "domain-unknown")
        }
    }

    func testRegistryRejectsNoDefaultDomain() throws {
        let registry = try writeRegistry([CredentialDomain(domainID: CredentialDomainID("only"))],
                                         defaultDomain: nil)
        XCTAssertThrowsError(try registry.resolve(nil)) { error in
            guard case DomainResolutionError.noDefaultDomain = error else {
                return XCTFail("unexpected: \(error)")
            }
        }
        // 但显式域仍然可用
        XCTAssertNoThrow(try registry.resolve(CredentialDomainID("only")))
    }

    func testRegistryRejectsPathEscapeAndDuplicates() throws {
        XCTAssertThrowsError(try writeRegistry([
            CredentialDomain(domainID: CredentialDomainID("a"), brokerPolicyFile: "../evil.json")
        ])) { error in
            guard case DomainResolutionError.policyEscapesCredentialRoot = error else {
                return XCTFail("unexpected: \(error)")
            }
        }
        XCTAssertThrowsError(try writeRegistry([
            CredentialDomain(domainID: CredentialDomainID("dup")),
            CredentialDomain(domainID: CredentialDomainID("dup"))
        ])) { error in
            guard case DomainResolutionError.malformed = error else {
                return XCTFail("unexpected: \(error)")
            }
        }
        XCTAssertThrowsError(try writeRegistry([
            CredentialDomain(domainID: CredentialDomainID("BadID"))
        ])) { error in
            guard case DomainResolutionError.invalidDomainID = error else {
                return XCTFail("unexpected: \(error)")
            }
        }
    }

    func testRegistryRejectsWrongSchema() throws {
        let url = workspace.appendingPathComponent("domains.json")
        try Data(#"{"schema":"deskbox-domains/v0","domains":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try DomainRegistry.load(from: url, credentialRoot: workspace))
    }

    func testResolveForBrokerRequiresExistingFiles() throws {
        let registry = try writeRegistry([
            CredentialDomain(domainID: CredentialDomainID("a"), brokerPolicyFile: "missing.json")
        ], defaultDomain: "a")
        XCTAssertThrowsError(try registry.resolveForBroker(CredentialDomainID("a"))) { error in
            guard case DomainResolutionError.policyMissing = error else {
                return XCTFail("unexpected: \(error)")
            }
        }
        // 文件存在则可用
        try Data(#"{"allowedHosts":["example.com"],"allowedSchemes":["https"],"maxResponseBytes":1024}"#.utf8)
            .write(to: workspace.appendingPathComponent("missing.json"))
        let resolved = try registry.resolveForBroker(CredentialDomainID("a"))
        XCTAssertNotNil(resolved.policyURL)
        XCTAssertNil(resolved.credentialsURL)
    }

    // MARK: - COW 跨域

    func testCowCloneRecordsDomainAndRejectsAdoption() throws {
        let base = workspace.appendingPathComponent("base.raw")
        try Data(repeating: 0xAB, count: 4096).write(to: base)
        let cowRoot = workspace.appendingPathComponent("cows", isDirectory: true)
        let cow = try CowDiskManager(root: cowRoot)
        let sandboxID = SandboxID(UUID().uuidString)

        let lease = try cow.createClone(source: base, sandboxID: sandboxID,
                                       domainID: CredentialDomainID("work"))
        XCTAssertEqual(lease.domainID.raw, "work")
        let marker = CowDiskManager.domainMarkerURL(forClone: lease.cloneURL)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "work")
        XCTAssertEqual(try CowDiskManager.recordedDomain(forClone: lease.cloneURL)?.raw, "work")

        // 同域收养：允许
        XCTAssertNoThrow(try cow.adoptClone(cloneURL: lease.cloneURL, sandboxID: sandboxID,
                                            domainID: CredentialDomainID("work")))
        // 跨域收养：必须拒绝（这是「把 A 域 clone 挪给 B 域」的攻击路径）
        XCTAssertThrowsError(try cow.adoptClone(cloneURL: lease.cloneURL, sandboxID: sandboxID,
                                                domainID: CredentialDomainID("personal"))) { error in
            let message = (error as? SandboxFailure)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("cow-domain-mismatch"), "unexpected: \(message)")
        }
    }

    func testCowRemoveDeletesDomainMarker() throws {
        let base = workspace.appendingPathComponent("base.raw")
        try Data(repeating: 0x01, count: 1024).write(to: base)
        let cow = try CowDiskManager(root: workspace.appendingPathComponent("cows", isDirectory: true))
        let lease = try cow.createClone(source: base, sandboxID: SandboxID(UUID().uuidString),
                                       domainID: CredentialDomainID("a"))
        try cow.removeClone(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.cloneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CowDiskManager.domainMarkerURL(forClone: lease.cloneURL).path))
    }

    // MARK: - 快照（I2）

    func testSnapshotAADBindsDomain() throws {
        let store = SnapshotStore(keyURL: workspace.appendingPathComponent("snapshot.key"))
        let metadata = SnapshotMetadata(
            sandboxID: "sandbox-1", bootID: "boot-1", manifestDigest: "m1",
            guestAssetVersion: 1, keyID: "k", createdAtUtc: "2026-01-01T00:00:00Z",
            hostBuild: "test", payloadSha256: "", domainID: "work"
        )
        let snapshotURL = workspace.appendingPathComponent("s.snap")
        try store.seal(payload: Data("vmstate".utf8), metadata: metadata, to: snapshotURL)

        // AAD 里必须能看到域
        let aad = try String(decoding: metadata.canonicalAAD(), as: UTF8.self)
        XCTAssertTrue(aad.contains("\"domainID\":\"work\""), aad)

        // 用另一个域的 gate 校验 → 拒绝
        let gateA = SnapshotGate(manifestDigest: "m1", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: nil,
                                domainID: CredentialDomainID("work"))
        XCTAssertNoThrow(try gateA.check(try store.readMetadata(at: snapshotURL)))
        let gateB = SnapshotGate(manifestDigest: "m1", guestAssetVersion: 1,
                                minimumAssetVersionFloor: 1, releaseKeys: nil,
                                domainID: CredentialDomainID("personal"))
        XCTAssertThrowsError(try gateB.check(try store.readMetadata(at: snapshotURL))) { error in
            guard case SnapshotError.domainMismatch(let stored, let current) = error else {
                return XCTFail("unexpected: \(error)")
            }
            XCTAssertEqual(stored, "work")
            XCTAssertEqual(current, "personal")
        }
    }

    /// 篡改磁盘上的 domainID：AAD 变化 → 解密必须失败（不只是闸门拒绝）。
    func testTamperedSnapshotDomainFailsDecryption() throws {
        let store = SnapshotStore(keyURL: workspace.appendingPathComponent("snapshot.key"))
        let metadata = SnapshotMetadata(
            sandboxID: "s", bootID: "b", manifestDigest: "m", guestAssetVersion: 1,
            keyID: "k", createdAtUtc: "2026-01-01T00:00:00Z", hostBuild: "t",
            payloadSha256: "", domainID: "work"
        )
        let snapshotURL = workspace.appendingPathComponent("t.snap")
        try store.seal(payload: Data("state".utf8), metadata: metadata, to: snapshotURL)

        var bytes = try Data(contentsOf: snapshotURL)
        // meta JSON 里把 work 改成 w0rk（同长度），AAD 不再匹配。
        if let range = bytes.range(of: Data("\"domainID\":\"work\"".utf8)) {
            bytes.replaceSubrange(range, with: Data("\"domainID\":\"w0rk\"".utf8))
            try bytes.write(to: snapshotURL)
        } else {
            return XCTFail("metadata 中未找到 domainID 字段")
        }
        XCTAssertThrowsError(try store.open(at: snapshotURL))
    }

    // MARK: - 属性矩阵（域 × 工作区 × grant 组合）

    /// 组合矩阵断言：不同域 ⇒ 不同 COW clone 路径 / 不同域标记 / 不同快照 AAD。
    /// 每台 VM 的 `vmInstanceID` 由 runtime 生成，这里用等价的位置标识（sandboxID + clone）做闭包证明。
    func testDomainWorkspaceGrantMatrixNeverSharesState() throws {
        let base = workspace.appendingPathComponent("base.raw")
        try Data(repeating: 0x11, count: 2048).write(to: base)
        let cow = try CowDiskManager(root: workspace.appendingPathComponent("cows", isDirectory: true))
        let store = SnapshotStore(keyURL: workspace.appendingPathComponent("k"))
        let domains: [CredentialDomainID] = ["personal", "work", "ci"].map { CredentialDomainID($0) }
        let workspaces: [WorkspaceID] = [.new(), .new()]
        let grants: [InjectionForm] = [.none, .bearer]

        struct Issued {
            let domain: CredentialDomainID
            let workspace: WorkspaceID
            let grant: InjectionForm
            let sandboxID: SandboxID
            let clonePath: String
            let vmInstanceID: String
            let aad: String
        }
        var issued: [Issued] = []
        for domain in domains {
            for workspaceID in workspaces {
                for grant in grants {
                    let sandboxID = SandboxID(UUID().uuidString)
                    let lease = try cow.createClone(source: base, sandboxID: sandboxID, domainID: domain)
                    let metadata = SnapshotMetadata(
                        sandboxID: sandboxID.raw, bootID: BootID(UUID().uuidString).raw,
                        manifestDigest: "m", guestAssetVersion: 1, keyID: "k",
                        createdAtUtc: "2026-01-01T00:00:00Z", hostBuild: "t",
                        payloadSha256: "", domainID: domain.raw
                    )
                    let aad = try String(decoding: metadata.canonicalAAD(), as: UTF8.self)
                    issued.append(Issued(domain: domain, workspace: workspaceID, grant: grant,
                                         sandboxID: sandboxID,
                                         clonePath: lease.cloneURL.standardizedFileURL.path,
                                         // 每个 sandbox 的 VM 实例 ID 独立（runtime 保证），
                                         // 这里用 lease 路径作为等价唯一性检查。
                                         vmInstanceID: lease.cloneURL.lastPathComponent,
                                         aad: aad))
                    // 快照可正常封装（域绑定在 AAD 内）
                    try store.seal(payload: Data("p".utf8), metadata: metadata,
                                   to: workspace.appendingPathComponent("\(sandboxID.raw).snap"))
                }
            }
        }
        XCTAssertEqual(issued.count, domains.count * workspaces.count * grants.count)
        XCTAssertEqual(Set(issued.map(\.clonePath)).count, issued.count, "COW clone 路径必须唯一")
        XCTAssertEqual(Set(issued.map(\.vmInstanceID)).count, issued.count, "VM 实例标识必须唯一")

        // 跨域任意两两组合：AAD 必须不同（域参与 AAD）。
        for a in issued where a.domain != issued.first!.domain {
            let other = issued.first { $0.domain != a.domain }!
            XCTAssertNotEqual(a.aad, other.aad)
        }
        // 同域不同 workspace：clone 仍必须唯一（不共享可写盘）。
        let sameDomain = issued.filter { $0.domain == domains[0] }
        XCTAssertEqual(Set(sameDomain.map(\.clonePath)).count, sameDomain.count)

        // 每一对「域不同」的组合都要被 gate 拒绝。
        for a in issued {
            for b in issued where a.domain != b.domain {
                let gate = SnapshotGate(manifestDigest: "m", guestAssetVersion: 1,
                                        minimumAssetVersionFloor: 1, releaseKeys: nil,
                                        domainID: a.domain)
                let metadata = SnapshotMetadata(
                    sandboxID: b.sandboxID.raw, bootID: "b", manifestDigest: "m",
                    guestAssetVersion: 1, keyID: "k", createdAtUtc: "2026-01-01T00:00:00Z",
                    hostBuild: "t", payloadSha256: "", domainID: b.domain.raw
                )
                XCTAssertThrowsError(try gate.check(metadata),
                                     "跨域 \(a.domain) <- \(b.domain) 必须拒绝")
            }
        }
    }

    // MARK: - helpers

    private func writeRegistry(_ domains: [CredentialDomain],
                               defaultDomain: String? = nil) throws -> DomainRegistry {
        let manifest = CredentialDomainsManifest(
            defaultDomain: defaultDomain.map { CredentialDomainID($0) },
            domains: domains
        )
        let url = workspace.appendingPathComponent("domains.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url)
        return try DomainRegistry.load(from: url, credentialRoot: workspace)
    }
}
