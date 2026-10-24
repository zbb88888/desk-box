import XCTest
@testable import DeskBoxVZ
@testable import DeskBoxCore

/// M2-2: OCI policy fail-closed（INV-06）。
final class OciPolicyTests: XCTestCase {
    private func bundleRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-oci-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
        return url
    }

    private func makeSpec(args: [String] = ["/workspace/app.sh"],
                          cwd: String = "/workspace",
                          env: [String]? = nil,
                          uid: Int? = nil,
                          privileged: Bool? = nil,
                          mounts: [OciRuntimeSpec.Mount]? = nil,
                          rootPath: String = "rootfs") -> OciRuntimeSpec {
        OciRuntimeSpec(
            ociVersion: "1.0.2",
            root: OciRuntimeSpec.Root(path: rootPath),
            process: OciRuntimeSpec.Process(args: args, cwd: cwd, env: env,
                                            user: uid.map { OciRuntimeSpec.User(uid: $0, gid: $0) }),
            mounts: mounts,
            linux: privileged.map { OciRuntimeSpec.Linux(namespaces: nil, privileged: $0) }
        )
    }

    func testValidSpecResolves() throws {
        let bundle = try bundleRoot()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let workload = try OciPolicyValidator.validate(spec: makeSpec(env: ["LANG=C"], uid: 65534), bundleDir: bundle)
        XCTAssertEqual(workload.argv, ["/workspace/app.sh"])
        XCTAssertEqual(workload.cwd, "/workspace")
        XCTAssertEqual(workload.env, ["LANG": "C"])
        XCTAssertEqual(workload.rootfsURL?.path, bundle.appendingPathComponent("rootfs").path)
    }

    func testCwdOutsideWorkspaceRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(cwd: "/etc"), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .cwdNotUnderWorkspace? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testEnvDbxPrefixRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(env: ["DBX_SESSION=evil"]), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .envKeyInvalid? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testEnvLowercaseRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(env: ["lang=c"]), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .envKeyInvalid? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testEnvReservedNameRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(env: ["PATH=/evil"]), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .envKeyInvalid? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testUidZeroRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(uid: 0), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .uidNotNobody? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testPrivilegedRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(privileged: true), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .privilegedRequested? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testMountOutsideWorkspaceRejected() {
        let mount = OciRuntimeSpec.Mount(destination: "/proc", source: "proc", type: "proc")
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(mounts: [mount]), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .mountOutsideWorkspace? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testMountAbsoluteSourceRejected() {
        let mount = OciRuntimeSpec.Mount(destination: "/workspace/data", source: "/Users/attacker", type: "bind")
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(mounts: [mount]), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .mountSourceSuspicious? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testRootOutsideBundleRejected() {
        let bundle = try! bundleRoot()
        defer { try? FileManager.default.removeItem(at: bundle) }
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(rootPath: "../escape"), bundleDir: bundle)) { error in
            guard case .ociRootOutsideBundle? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }

    func testEmptyArgsRejected() {
        XCTAssertThrowsError(try OciPolicyValidator.validate(spec: makeSpec(args: []), bundleDir: URL(fileURLWithPath: "/tmp"))) { error in
            guard case .emptyArgs? = error as? OciPolicyError else { return XCTFail("got \(error)") }
        }
    }
}
