import XCTest
import Darwin
import Foundation
@testable import dbx_poc
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M24b/c：daemon 并发与停机行为（真 UNIX socket，不起 VM）。
///
/// 资源纪律：每个用例一个独立临时目录（sock + supportRoot），`addTeardownBlock`
/// 负责「停 daemon → 等线程退出 → 删目录」，失败路径同样执行。
final class DaemonServeTests: XCTestCase {

    private final class Running: @unchecked Sendable {
        let dir: URL
        let sock: String
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var finished = false
        init(dir: URL, sock: String) { self.dir = dir; self.sock = sock }
        func markFinished() { lock.lock(); finished = true; lock.unlock(); done.signal() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }

    /// 起一个 daemon（后台线程跑 serveLoop），等 socket 就绪。
    private func startDaemon() throws -> Running {
        // sun_path 上限 104：用 /tmp 短路径而不是 NSTemporaryDirectory（/var/folders/… 太长）。
        let dir = URL(fileURLWithPath: "/tmp/dbxt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let running = Running(dir: dir, sock: dir.appendingPathComponent("d.sock").path)
        let daemon = SandboxDaemon(sockPath: running.sock, supportRoot: dir)
        let thread = Thread {
            try? daemon.serveLoop()
            running.markFinished()
        }
        thread.start()

        addTeardownBlock {
            // 用例没自己停机（或中途失败）时兜底停机，保证不留线程/socket/目录。
            if !running.isFinished {
                _ = try? DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: running.sock)
                _ = running.done.wait(timeout: .now() + 10)
            }
            try? FileManager.default.removeItem(at: dir)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "临时目录未清理：\(dir.path)")
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: running.sock)) != nil {
                return running
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("daemon 未在 5s 内就绪")
        return running
    }

    private func rawConnect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { buf in
            buf.withMemoryRebound(to: CChar.self, capacity: 104) { p in
                for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0, "connect errno=\(errno)")
        return fd
    }

    // MARK: 基本协议

    func testPsOnEmptyDaemon() throws {
        let d = try startDaemon()
        let resp = try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.sandboxes?.count, 0)
    }

    func testSocketIsOwnerOnly() throws {
        let d = try startDaemon()
        let attrs = try FileManager.default.attributesOfItem(atPath: d.sock)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectionsSurfaceDecisionErrors() throws {
        let d = try startDaemon()
        func rejected(_ r: DaemonRequest, _ needle: String, line: UInt = #line) {
            XCTAssertThrowsError(try DaemonClient.send(request: r, sockPath: d.sock), line: line) {
                XCTAssertTrue("\($0)".contains(needle), "期望 \(needle)，实际 \($0)", line: line)
            }
        }
        rejected(DaemonRequest(kind: "nope"), "unknown kind=nope")
        rejected(DaemonRequest(kind: "run"), "run: --manifestPath required")
        var exec = DaemonRequest(kind: "exec"); exec.sandboxId = "ghost"; exec.argv = ["/bin/echo"]
        rejected(exec, "exec: sandbox not found: ghost")
        var rm = DaemonRequest(kind: "rm"); rm.sandboxId = "ghost"
        rejected(rm, "rm: sandbox not found: ghost")
        var poll = DaemonRequest(kind: "ptyPoll"); poll.ptySessionId = "ghost"
        rejected(poll, "ptyPoll: pty session not found")
        // 拒绝之后 daemon 仍然健康。
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock).ok)
    }

    func testMalformedJsonRejectedAndDaemonSurvives() throws {
        let d = try startDaemon()
        let fd = rawConnect(d.sock)
        defer { close(fd) }
        let junk = Array("{not json\n".utf8)
        _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        XCTAssertGreaterThan(n, 0)
        let text = String(decoding: buf[0..<max(n, 0)], as: UTF8.self)
        XCTAssertTrue(text.contains("\"ok\":false"), text)
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock).ok)
    }

    // MARK: M24b 并发（队头阻塞回归）

    /// 旧实现 accept 后 `queue.sync` 串行处理：一个连上却不发请求的客户端会卡死整个 daemon。
    func testStalledClientDoesNotBlockOtherRequests() throws {
        let d = try startDaemon()
        let stalled = rawConnect(d.sock)   // 连上、不发任何字节
        defer { close(stalled) }
        Thread.sleep(forTimeInterval: 0.1) // 确保 daemon 已 accept 并进入 read

        let started = Date()
        let resp = try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(resp.ok)
        XCTAssertLessThan(elapsed, 2.0, "ps 被卡住的连接阻塞了 \(elapsed)s（队头阻塞回归）")
    }

    func testManyConcurrentClients() throws {
        let d = try startDaemon()
        let n = 64
        let okCount = Counter()
        DispatchQueue.concurrentPerform(iterations: n) { i in
            // 混合合法 / 被拒请求，验证并发下状态快照不撕裂、不崩溃。
            if i % 2 == 0 {
                if (try? DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock))?.ok == true { okCount.increment() }
            } else {
                var r = DaemonRequest(kind: "stop"); r.sandboxId = "ghost-\(i)"
                do { _ = try DaemonClient.send(request: r, sockPath: d.sock) }
                catch { if "\(error)".contains("stop: sandbox not found: ghost-\(i)") { okCount.increment() } }
            }
        }
        XCTAssertEqual(okCount.value, n)
    }

    // MARK: M24c 停机

    func testShutdownAcksReturnsAndUnlinksSocket() throws {
        let d = try startDaemon()
        let resp = try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: d.sock)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(d.done.wait(timeout: .now() + 10), .success, "serveLoop 未在 shutdown 后返回")
        d.markFinished()   // 已消费信号；告知 teardown 无需再停
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.sock), "shutdown 后 socket 残留")
        XCTAssertThrowsError(try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock))
    }

    func testShutdownWithStalledClientStillExitsBounded() throws {
        let d = try startDaemon()
        let stalled = rawConnect(d.sock)
        defer { close(stalled) }
        Thread.sleep(forTimeInterval: 0.1)
        let started = Date()
        XCTAssertTrue(try DaemonClient.send(request: DaemonRequest(kind: "shutdown"), sockPath: d.sock).ok)
        XCTAssertEqual(d.done.wait(timeout: .now() + 12), .success)
        d.markFinished()
        XCTAssertLessThan(Date().timeIntervalSince(started), 12, "卡住的客户端拖死了停机")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.sock))
    }

    func testRunWithMissingManifestFailsCleanlyAndLeavesNoSession() throws {
        let d = try startDaemon()
        var run = DaemonRequest(kind: "run")
        run.manifestPath = d.dir.appendingPathComponent("does-not-exist.json").path
        run.cowRoot = d.dir.appendingPathComponent("cows").path
        XCTAssertThrowsError(try DaemonClient.send(request: run, sockPath: d.sock))
        XCTAssertEqual(try DaemonClient.send(request: DaemonRequest(kind: "ps"), sockPath: d.sock).sandboxes?.count, 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// M24b：registry.json 并发 read-modify-write（多 VZRuntime 实例 → 多 SandboxRegistry 实例）。
final class SandboxRegistryConcurrencyTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbx-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testConcurrentUpsertsFromSeparateInstancesLoseNothing() throws {
        let root = try tempRoot()
        let n = 48
        let ids = (0..<n).map { _ in SandboxID.new() }
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: n) { i in
            do {
                // 每个「沙箱」一个独立 registry 实例，正是并发 daemon 的真实形态。
                let registry = try SandboxRegistry(root: root)
                try registry.upsert(RegisteredSandbox(
                    sandboxID: ids[i], bootID: .new(), status: .running,
                    clonePath: root.appendingPathComponent("c\(i).raw").path,
                    hostPID: ProcessInfo.processInfo.processIdentifier))
            } catch { failures.increment() }
        }
        XCTAssertEqual(failures.value, 0)
        let loaded = try SandboxRegistry(root: root).load()
        XCTAssertEqual(Set(loaded.map(\.sandboxID)), Set(ids), "并发 upsert 丢失更新")
    }

    func testConcurrentUpsertDestroySweepKeepsRegistryConsistent() throws {
        let root = try tempRoot()
        let n = 40
        let ids = (0..<n).map { _ in SandboxID.new() }
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: n) { i in
            do {
                let registry = try SandboxRegistry(root: root)
                try registry.upsert(RegisteredSandbox(
                    sandboxID: ids[i], bootID: .new(), status: .running,
                    clonePath: root.appendingPathComponent("c\(i).raw").path,
                    hostPID: ProcessInfo.processInfo.processIdentifier))
                _ = try registry.sweep()                       // 活 PID：不得误删
                if i % 2 == 0 { try registry.markDestroyed(sandboxID: ids[i]) }
            } catch { failures.increment() }
        }
        XCTAssertEqual(failures.value, 0)
        let survivors = Set(try SandboxRegistry(root: root).load().map(\.sandboxID))
        let expected = Set(ids.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        XCTAssertEqual(survivors, expected)
    }

    /// 回归：processIsAlive 曾读取脏 errno，把活进程判成死的 → sweep 删掉活沙箱的 COW 盘。
    func testProcessIsAliveIgnoresStaleErrno() {
        let me = ProcessInfo.processInfo.processIdentifier
        for stale in [ENOENT, ESRCH, EINTR, EACCES] {
            errno = stale
            XCTAssertTrue(SandboxRegistry.processIsAlive(me), "stale errno=\(stale) 导致活进程被判死")
        }
        errno = 0
        XCTAssertFalse(SandboxRegistry.processIsAlive(999_999_999))
        errno = EPERM   // 脏 EPERM 也不能把死进程判活
        XCTAssertFalse(SandboxRegistry.processIsAlive(999_999_999))
        XCTAssertTrue(SandboxRegistry.processIsAlive(1), "launchd（EPERM）应视为存活")
    }

    func testSweepNeverRemovesLiveSandboxCloneUnderStaleErrno() throws {
        let root = try tempRoot()
        let clone = root.appendingPathComponent("live.raw")
        try Data("live".utf8).write(to: clone)
        let registry = try SandboxRegistry(root: root)
        try registry.upsert(RegisteredSandbox(
            sandboxID: .new(), bootID: .new(), status: .running,
            clonePath: clone.path, hostPID: ProcessInfo.processInfo.processIdentifier))
        errno = ENOENT
        let report = try registry.sweep()
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path), "活沙箱的 COW 盘被 sweep 删除")
        XCTAssertEqual(try registry.load().count, 1)
    }

    /// 回归：崩溃后 sweep 必须连同 M23 域标记 sidecar 一起清掉（此前每次崩溃泄漏一个）。
    func testSweepRemovesDomainMarkerOfOrphanButKeepsLiveOnes() throws {
        let root = try tempRoot()
        let dead = root.appendingPathComponent("sandbox-dead.vhd")
        let live = root.appendingPathComponent("sandbox-live.vhd")
        for url in [dead, live] {
            try Data("disk".utf8).write(to: url)
            try Data("work".utf8).write(to: CowDiskManager.domainMarkerURL(forClone: url))
        }
        let registry = try SandboxRegistry(root: root)
        try registry.upsert(RegisteredSandbox(
            sandboxID: .new(), bootID: .new(), status: .running,
            clonePath: dead.path, hostPID: Int32(999_999_999)))
        try registry.upsert(RegisteredSandbox(
            sandboxID: .new(), bootID: .new(), status: .running,
            clonePath: live.path, hostPID: ProcessInfo.processInfo.processIdentifier))

        let report = try registry.sweep()
        XCTAssertEqual(report.removedCloneFiles, [dead.path])
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(names, ["registry.json", "registry.lock", "sandbox-live.vhd", "sandbox-live.vhd.domain"],
                       "孤儿的 clone+sidecar 应清除，活沙箱的应原样保留")
    }

    func testNoTempFilesLeftBehind() throws {
        let root = try tempRoot()
        let registry = try SandboxRegistry(root: root)
        for _ in 0..<5 {
            try registry.upsert(RegisteredSandbox(
                sandboxID: .new(), bootID: .new(), status: .running,
                clonePath: root.appendingPathComponent("x.raw").path,
                hostPID: ProcessInfo.processInfo.processIdentifier))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(names, ["registry.json", "registry.lock"], "registry 写入留下了临时文件：\(names)")
    }
}
