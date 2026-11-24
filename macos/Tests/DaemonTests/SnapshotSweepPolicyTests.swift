import XCTest
import Foundation
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M27：快照目录清扫策略（跨进程安全）。
final class SnapshotSweepPolicyTests: XCTestCase {
    private let me = ProcessInfo.processInfo.processIdentifier
    private let deadPID: Int32 = 999_999_999
    private func alive(_ pid: Int32) -> Bool { pid == me || pid == 1 }

    private func verdict(_ name: String, live: Set<String> = [], age: TimeInterval? = 1) -> SnapshotSweepPolicy.Verdict {
        SnapshotSweepPolicy.verdict(name: name, liveSandboxIDs: live, age: age, isProcessAlive: alive)
    }

    // MARK: 命名

    func testTempNamesCarryOwnerPID() {
        let s = SnapshotSweepPolicy.suspendTempName()
        let r = SnapshotSweepPolicy.restoreTempName()
        XCTAssertTrue(s.hasPrefix("tmp-p\(me)-") && s.hasSuffix(".vzstate"), s)
        XCTAssertTrue(r.hasPrefix("tmp-restore-p\(me)-") && r.hasSuffix(".vzstate"), r)
        XCTAssertEqual(SnapshotSweepPolicy.ownerPID(ofTempName: s), me)
        XCTAssertEqual(SnapshotSweepPolicy.ownerPID(ofTempName: r), me)
        XCTAssertNotEqual(SnapshotSweepPolicy.suspendTempName(), s, "每次调用必须唯一")
    }

    func testOwnerPIDParsingRejectsMalformedAndDangerousValues() {
        let uuid = UUID().uuidString
        for name in [
            "tmp-\(uuid).vzstate",            // 旧格式
            "tmp-restore-\(uuid).vzstate",    // 旧格式
            "tmp-p-\(uuid).vzstate",          // 无数字
            "tmp-p12x-\(uuid).vzstate",       // 数字后不是 '-'
            "tmp-p0-\(uuid).vzstate",         // kill(0, 0) 是「本进程组」——永远「活着」
            "tmp-p-1-\(uuid).vzstate",        // kill(-1, 0) 是「所有进程」
            "tmp-p99999999999999-\(uuid).vzstate", // 溢出 Int32
            "tmp-pabc.vzstate",
            "other-p12-x.vzstate",
        ] {
            XCTAssertNil(SnapshotSweepPolicy.ownerPID(ofTempName: name), name)
        }
        XCTAssertEqual(SnapshotSweepPolicy.ownerPID(ofTempName: "tmp-p4242-x"), 4242)
    }

    // MARK: 判定

    func testInFlightFileOfLiveOwnerIsKept() {
        // 核心回归：另一个进程的 sweep 不得删除活着的 daemon 正在写的临时文件。
        XCTAssertEqual(verdict(SnapshotSweepPolicy.suspendTempName(pid: me)), .keep)
        XCTAssertEqual(verdict(SnapshotSweepPolicy.restoreTempName(pid: me)), .keep)
        XCTAssertEqual(verdict(SnapshotSweepPolicy.suspendTempName(pid: me), age: nil), .keep)
    }

    func testCrashResidueOfDeadOwnerIsRemovedImmediately() {
        XCTAssertEqual(verdict(SnapshotSweepPolicy.suspendTempName(pid: deadPID), age: 0), .remove)
        XCTAssertEqual(verdict(SnapshotSweepPolicy.restoreTempName(pid: deadPID), age: 0), .remove)
    }

    func testLegacyTempFilesGetAGraceWindow() {
        let legacy = "tmp-\(UUID().uuidString).vzstate"
        XCTAssertEqual(verdict(legacy, age: 5), .keep, "可能是仍在运行的旧版本 daemon 的在途文件")
        XCTAssertEqual(verdict(legacy, age: SnapshotSweepPolicy.legacyGrace), .keep)
        XCTAssertEqual(verdict(legacy, age: SnapshotSweepPolicy.legacyGrace + 1), .remove)
        XCTAssertEqual(verdict(legacy, age: nil), .keep, "取不到 mtime 时宁可晚删")
        XCTAssertEqual(verdict("tmp-restore-\(UUID().uuidString).vzstate", age: 10_000), .remove)
    }

    func testMaxAgeBeatsLiveOwner() {
        // PID 复用：属主早已死亡、PID 被别的进程占用——不能永久残留。
        XCTAssertEqual(verdict(SnapshotSweepPolicy.suspendTempName(pid: me), age: SnapshotSweepPolicy.maxAge + 1), .remove)
        XCTAssertEqual(verdict(SnapshotSweepPolicy.suspendTempName(pid: me), age: SnapshotSweepPolicy.maxAge - 1), .keep)
    }

    func testSnapFilesFollowRegistryLiveness() {
        XCTAssertEqual(verdict("ABC.snap", live: ["ABC"]), .keep)
        XCTAssertEqual(verdict("ABC.snap", live: ["XYZ"]), .remove)
        XCTAssertEqual(verdict("ABC.snap", live: [], age: nil), .remove)
    }

    func testUnrelatedFilesAreIgnored() {
        for name in ["notes.txt", ".DS_Store", "ABC.snap.bak", "tmpfile", "snapshot.key"] {
            XCTAssertEqual(verdict(name, age: 1_000_000), .ignore, name)
        }
    }

    // MARK: 经 VZRuntime.sweepOrphans 的集成（真实目录，不起 VM）

    func testSweepOrphansAppliesPolicyOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-sweep-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cows = root.appendingPathComponent("cows", isDirectory: true)
        let snaps = cows.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snaps, withIntermediateDirectories: true)

        func plant(_ name: String, ageSeconds: TimeInterval = 0) throws {
            let url = snaps.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if ageSeconds > 0 {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
            }
        }
        let liveID = SandboxID.new()
        let liveTemp = SnapshotSweepPolicy.suspendTempName(pid: me)
        let liveRestore = SnapshotSweepPolicy.restoreTempName(pid: me)
        let deadTemp = SnapshotSweepPolicy.suspendTempName(pid: deadPID)
        let legacyYoung = "tmp-\(UUID().uuidString).vzstate"
        let legacyOld = "tmp-restore-\(UUID().uuidString).vzstate"
        try plant(liveTemp); try plant(liveRestore); try plant(deadTemp)
        try plant(legacyYoung); try plant(legacyOld, ageSeconds: SnapshotSweepPolicy.legacyGrace + 60)
        try plant("\(liveID.description).snap"); try plant("\(SandboxID.new().description).snap")
        try plant("README.txt")

        // 活沙箱登记在 registry（属主 = 本进程）。
        let clone = cows.appendingPathComponent("sandbox-live.vhd")
        try Data("disk".utf8).write(to: clone)
        try SandboxRegistry(root: cows).upsert(RegisteredSandbox(
            sandboxID: liveID, bootID: .new(), status: .running, clonePath: clone.path, hostPID: me))

        let runtime = try VZRuntime(cowRoot: cows, enableConsole: false, enableControlSocket: false)
        let report = try runtime.sweepOrphans()
        XCTAssertTrue(report.isEmpty)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: snaps.path))
        XCTAssertEqual(left, [liveTemp, liveRestore, legacyYoung, "\(liveID.description).snap", "README.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))
    }
}
