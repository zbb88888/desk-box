import XCTest
import Foundation
@testable import DeskBoxGUI

/// M33：Stats 面板的计算与状态。
final class StatsModelTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    // MARK: CPUPercentCalculator

    func testFirstSampleOnlyEstablishesBaseline() {
        var calc = CPUPercentCalculator()
        XCTAssertNil(calc.next(cpuUsageMicros: 5_000_000, nowNanos: 10 * second, cores: 8))
        // 1 秒墙钟内用了 0.5 秒 CPU → 50%
        XCTAssertEqual(calc.next(cpuUsageMicros: 5_500_000, nowNanos: 11 * second, cores: 8)!, 50, accuracy: 0.001)
        XCTAssertEqual(calc.next(cpuUsageMicros: 5_500_000, nowNanos: 12 * second, cores: 8)!, 0, accuracy: 0.001)
    }

    func testMultiCoreCanExceed100ButIsCapped() {
        var calc = CPUPercentCalculator()
        _ = calc.next(cpuUsageMicros: 0, nowNanos: 1 * second, cores: 4)
        XCTAssertEqual(calc.next(cpuUsageMicros: 3_000_000, nowNanos: 2 * second, cores: 4)!, 300, accuracy: 0.001)
        XCTAssertEqual(calc.next(cpuUsageMicros: 99_000_000, nowNanos: 3 * second, cores: 4)!, 400, accuracy: 0.001)
    }

    func testCounterGoingBackwardsRebaselinesInsteadOfReportingZero() {
        // guest 重启 / 换了一个沙箱：计数器变小。不能报 0%，也不能报一个天文数字。
        var calc = CPUPercentCalculator()
        _ = calc.next(cpuUsageMicros: 9_000_000, nowNanos: 1 * second, cores: 8)
        XCTAssertNil(calc.next(cpuUsageMicros: 100_000, nowNanos: 2 * second, cores: 8))
        XCTAssertEqual(calc.next(cpuUsageMicros: 350_000, nowNanos: 3 * second, cores: 8)!, 25, accuracy: 0.001)
    }

    func testMissingCounterAndNonAdvancingClock() {
        var calc = CPUPercentCalculator()
        _ = calc.next(cpuUsageMicros: 1_000_000, nowNanos: 1 * second, cores: 8)
        XCTAssertNil(calc.next(cpuUsageMicros: nil, nowNanos: 2 * second, cores: 8))
        XCTAssertNil(calc.next(cpuUsageMicros: 2_000_000, nowNanos: 3 * second, cores: 8), "计数器缺失之后要重新建立基线")
        XCTAssertNil(calc.next(cpuUsageMicros: 3_000_000, nowNanos: 3 * second, cores: 8), "时钟未前进")
        XCTAssertNotNil(calc.next(cpuUsageMicros: 3_100_000, nowNanos: 4 * second, cores: 8))
    }

    // MARK: StatsModel

    private func response(cpu: UInt64?, mem: UInt64?, error: String? = nil) -> Result<DaemonResponse, Error> {
        var stats = SandboxStats()
        stats.cpuUsageUsec = cpu; stats.memoryCurrentBytes = mem; stats.memoryMaxBytes = 1 << 30
        stats.pidsCurrent = 3; stats.pidsMax = 64; stats.activeExecGroups = 1; stats.statsError = error
        var r = DaemonResponse(ok: true)
        r.stats = stats
        return .success(r)
    }

    private func model() -> StatsModel { StatsModel(client: DaemonSocketClient(sockPath: "/nonexistent")) }

    func testApplyFillsMetricsAndHistory() {
        let m = model()
        m.select("A")
        m.apply(response(cpu: 1_000_000, mem: 100), nowNanos: 1 * second, cores: 8)
        XCTAssertEqual(m.memCurrent, 100)
        XCTAssertEqual(m.pidsCurrent, 3)
        XCTAssertNil(m.cpuPercent, "首个样本没有 CPU%")
        XCTAssertTrue(m.history.isEmpty)
        m.apply(response(cpu: 1_250_000, mem: 200), nowNanos: 2 * second, cores: 8)
        XCTAssertEqual(m.cpuPercent!, 25, accuracy: 0.001)
        XCTAssertEqual(m.history, [m.cpuPercent!])
        XCTAssertEqual(m.memCurrent, 200)
        XCTAssertNil(m.statsError)
    }

    func testSwitchingSandboxResetsBaselineAndData() {
        // 回归：此前切换后第一个 CPU% 是「B 的计数器 − A 的计数器」。
        let m = model()
        m.select("A")
        m.apply(response(cpu: 1_000_000, mem: 100), nowNanos: 1 * second, cores: 8)
        m.apply(response(cpu: 2_000_000, mem: 100), nowNanos: 2 * second, cores: 8)
        XCTAssertNotNil(m.cpuPercent)

        m.select("B")
        XCTAssertNil(m.cpuPercent); XCTAssertNil(m.memCurrent); XCTAssertTrue(m.history.isEmpty)
        m.apply(response(cpu: 900_000_000, mem: 5), nowNanos: 3 * second, cores: 8)
        XCTAssertNil(m.cpuPercent, "B 的第一个样本只建立基线")
        XCTAssertEqual(m.memCurrent, 5)

        m.select("B")   // 选同一个：不重置
        XCTAssertEqual(m.memCurrent, 5)
    }

    func testFailureClearsStaleNumbersAndShowsReason() {
        let m = model()
        m.select("A")
        m.apply(response(cpu: 1_000_000, mem: 100), nowNanos: 1 * second, cores: 8)
        m.apply(.failure(DaemonClientError.rejected("request rejected (kind=stats): stats: sandbox not found: A")),
                nowNanos: 2 * second, cores: 8)
        XCTAssertNil(m.memCurrent, "沙箱没了，旧数字不能继续挂在界面上")
        XCTAssertNil(m.cpuPercent)
        XCTAssertTrue(m.statsError?.contains("沙箱不存在") ?? false, m.statsError ?? "nil")
        // 恢复后重新建立基线。
        m.apply(response(cpu: 5_000_000, mem: 7), nowNanos: 3 * second, cores: 8)
        XCTAssertNil(m.cpuPercent)
        XCTAssertNil(m.statsError)
        XCTAssertEqual(m.memCurrent, 7)
    }

    func testGuestReportedStatsErrorIsSurfacedWithPartialData() {
        let m = model()
        m.select("A")
        m.apply(response(cpu: nil, mem: 42, error: "cgroup unavailable"), nowNanos: 1 * second, cores: 8)
        XCTAssertEqual(m.statsError, "cgroup unavailable")
        XCTAssertEqual(m.memCurrent, 42)
        XCTAssertNil(m.cpuPercent)
    }

    func testHistoryIsBounded() {
        let m = model()
        m.select("A")
        for i in 0..<(StatsModel.historyLimit + 30) {
            m.apply(response(cpu: UInt64(i) * 100_000, mem: 1), nowNanos: UInt64(i + 1) * second, cores: 8)
        }
        XCTAssertEqual(m.history.count, StatsModel.historyLimit)
    }

    func testLateResponseForPreviousSelectionIsDropped() throws {
        // 真实 I/O：对 A 的采样发出后立刻切到 B；A 的响应回来时不得写入。
        let dir = URL(fileURLWithPath: "/tmp/dbxst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: #"{"ok":true,"stats":{"memoryCurrentBytes":777,"cpuUsageUsec":1}}"#)
        addTeardownBlock { daemon.stop() }

        let m = StatsModel(client: DaemonSocketClient(sockPath: sock))
        m.select("A")
        let done = expectation(description: "sample")
        m.sample { done.fulfill() }
        m.select("B")                       // 响应还在路上
        wait(for: [done], timeout: 5)
        XCTAssertNil(m.memCurrent, "A 的迟到响应写进了 B 的面板")
        XCTAssertEqual(m.selectedId, "B")

        let again = expectation(description: "sample B")
        m.sample { again.fulfill() }
        wait(for: [again], timeout: 5)
        XCTAssertEqual(m.memCurrent, 777)
    }

    func testSampleWithNoSelectionDoesNothing() {
        let m = model()
        let done = expectation(description: "noop")
        m.sample { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertNil(m.statsError)
    }

    // MARK: WorkspaceSync 前置检查

    func testWorkspacePrecheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)

        XCTAssertNil(WorkspaceSync.precheck(sandboxId: "SB", path: dir.path))
        XCTAssertEqual(WorkspaceSync.precheck(sandboxId: "", path: dir.path), "先填 sandbox id")
        XCTAssertEqual(WorkspaceSync.precheck(sandboxId: "   ", path: dir.path), "先填 sandbox id")
        XCTAssertEqual(WorkspaceSync.precheck(sandboxId: "SB", path: ""), "先选择 workspace 目录")
        XCTAssertTrue(WorkspaceSync.precheck(sandboxId: "SB", path: file.path)?.hasPrefix("不是目录") ?? false)
        XCTAssertTrue(WorkspaceSync.precheck(sandboxId: "SB", path: dir.path + "/nope")?.hasPrefix("目录不存在") ?? false)
    }

    func testWorkspaceSyncFailsLocallyWithoutContactingDaemon() throws {
        let dir = URL(fileURLWithPath: "/tmp/dbxws-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("d.sock").path
        let daemon = FakeDaemon(path: sock, reply: #"{"ok":true,"stdout":"ws-sync ok wsId=1 files=1 bytes=1"}"#)
        addTeardownBlock { daemon.stop() }
        let client = DaemonSocketClient(sockPath: sock)

        let bad = expectation(description: "bad")
        WorkspaceSync.sync(client: client, sandboxId: "SB", path: dir.path + "/missing") { text, ok in
            XCTAssertFalse(ok); XCTAssertTrue(text.hasPrefix("目录不存在")); bad.fulfill()
        }
        wait(for: [bad], timeout: 2)
        XCTAssertTrue(daemon.requests.isEmpty)

        let good = expectation(description: "good")
        WorkspaceSync.sync(client: client, sandboxId: " SB ", path: dir.path) { text, ok in
            XCTAssertTrue(ok); XCTAssertEqual(text, "ws-sync ok wsId=1 files=1 bytes=1"); good.fulfill()
        }
        wait(for: [good], timeout: 5)
        let line = try XCTUnwrap(daemon.requests.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "wsSync")
        XCTAssertEqual(object["sandboxId"] as? String, "SB", "首尾空白应被去掉")
        XCTAssertEqual(object["workspaceDir"] as? String, dir.path)
    }
}
