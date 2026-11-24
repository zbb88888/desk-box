import XCTest
@testable import DeskBoxCore

/// M37：exec 的 argv[0] / cwd 白名单按规范路径判断。
final class ExecPathPolicyTests: XCTestCase {
    func testFixedBinariesAndWorkspacePaths() {
        for ok in ["/bin/echo", "/bin/sh", "/bin/hardening-probe", "/workspace/run.sh", "/workspace/a/b/tool", "/workspace/..hidden", "/workspace/a..b"] {
            XCTAssertTrue(ExecPathPolicy.allowsExecutable(ok), ok)
        }
    }

    func testDotDotCannotEscapeTheWorkspacePrefix() {
        // 回归：此前是 hasPrefix("/workspace/")。
        for bad in ["/workspace/../bin/busybox", "/workspace/a/../../bin/sh", "/workspace/..", "/workspace/./run.sh",
                    "/workspace//run.sh", "/workspace/a/", "/workspace/", "/workspace", "/workspacex/run.sh",
                    "workspace/run.sh", "/bin/busybox", "/bin/sh ", "", "/workspace/a\u{0}b"] {
            XCTAssertFalse(ExecPathPolicy.allowsExecutable(bad), bad)
        }
    }

    func testWorkingDirectory() {
        XCTAssertTrue(ExecPathPolicy.allowsWorkingDirectory(nil))
        XCTAssertTrue(ExecPathPolicy.allowsWorkingDirectory("/workspace"))
        XCTAssertTrue(ExecPathPolicy.allowsWorkingDirectory("/workspace/src/deep"))
        for bad in ["/workspace/../etc", "/workspace/src/../../etc", "/workspace/.", "/workspace/", "/workspace//src",
                    "/etc", "/", "", "/workspace/src/", "/workspaces"] {
            XCTAssertFalse(ExecPathPolicy.allowsWorkingDirectory(bad), bad)
        }
    }

    func testStatsCapabilityFieldIsOptionalOnTheWire() throws {
        // 旧 guest 的 stats 应答没有 workspaceSyncVersion；新 guest 有。两者都必须能解码。
        let old = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"cpuUsageUsec":1,"memoryCurrentBytes":2,"memoryMaxBytes":null,"pidsCurrent":3,"pidsMax":null,"activeExecGroups":0}"#.utf8))
        XCTAssertNil(old.workspaceSyncVersion)
        let new = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"cpuUsageUsec":1,"memoryCurrentBytes":2,"memoryMaxBytes":null,"pidsCurrent":3,"pidsMax":null,"activeExecGroups":0,"workspaceSyncVersion":2}"#.utf8))
        XCTAssertEqual(new.workspaceSyncVersion, 2)
        let errorOnly = try JSONDecoder().decode(SandboxStats.self, from: Data(#"{"statsError":"cgroup2 采样不可读","workspaceSyncVersion":2}"#.utf8))
        XCTAssertEqual(errorOnly.workspaceSyncVersion, 2)
        XCTAssertNotNil(errorOnly.statsError)
    }
}
