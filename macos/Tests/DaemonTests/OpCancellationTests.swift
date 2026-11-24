import XCTest
import Foundation
@testable import dbx_poc

/// M26b：在途操作取消令牌。
final class OpCancellationTests: XCTestCase {

    func testFreshTokenAllowsOperations() throws {
        let token = OpCancellation()
        XCTAssertFalse(token.isCancelled)
        XCTAssertNoThrow(try token.checkNotCancelled(op: "exec"))
    }

    func testCancelRejectsQueuedOperationsWithReasonCode() {
        let token = OpCancellation()
        token.cancel(reason: "sandbox is being removed")
        XCTAssertTrue(token.isCancelled)
        XCTAssertThrowsError(try token.checkNotCancelled(op: "exec")) {
            XCTAssertEqual("\($0)", "DBX-OP-CANCELLED: exec aborted (sandbox is being removed)")
        }
        XCTAssertEqual("\(token.cancelledError(op: "wsSync"))", "DBX-OP-CANCELLED: wsSync aborted (sandbox is being removed)")
    }

    func testCancelFiresRegisteredHandlerEveryTime() {
        let token = OpCancellation()
        let fired = Box(0)
        token.register { fired.value += 1 }
        token.cancel(reason: "a")
        token.cancel(reason: "b")   // 幂等：再次取消仍会打断当前登记的任务
        XCTAssertEqual(fired.value, 2)
        token.unregister()
        token.cancel(reason: "c")
        XCTAssertEqual(fired.value, 2, "unregister 之后不得再调用旧句柄")
    }

    func testRegisterAfterCancelFiresImmediately() {
        // 竞争窗：cancel() 先到、任务后登记——任务必须仍被取消。
        let token = OpCancellation()
        token.cancel(reason: "x")
        let fired = Box(0)
        token.register { fired.value += 1 }
        XCTAssertEqual(fired.value, 1)
    }

    func testResetOnlyClearsOwnReason() throws {
        let token = OpCancellation()
        token.cancel(reason: "sandbox is being stopped")
        token.reset(ifReason: "sandbox is being stopped")
        XCTAssertFalse(token.isCancelled)
        XCTAssertNoThrow(try token.checkNotCancelled(op: "exec"))

        // stop 期间被 rm --force 接管：stop 的 reset 不得抹掉 rm 的取消。
        token.cancel(reason: "sandbox is being stopped")
        token.cancel(reason: "sandbox is being removed")
        token.reset(ifReason: "sandbox is being stopped")
        XCTAssertTrue(token.isCancelled)
        XCTAssertThrowsError(try token.checkNotCancelled(op: "exec")) {
            XCTAssertTrue("\($0)".contains("being removed"), "\($0)")
        }
    }

    // MARK: runBlocking 集成

    func testRunBlockingWithoutCancelReturnsValue() throws {
        let token = OpCancellation()
        XCTAssertEqual(try runBlocking(cancellation: token) { 42 }, 42)
        XCTAssertEqual(try runBlocking { "plain" }, "plain")
    }

    func testCancelInterruptsSleepingBodyPromptly() {
        let token = OpCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel(reason: "test") }
        let started = Date()
        XCTAssertThrowsError(try runBlocking(cancellation: token) {
            // 与 VZRuntime.execute 的等待方式一致：循环 Task.sleep。
            for _ in 0..<600 { try await Task.sleep(for: .milliseconds(50)) }
            return 1
        }) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "取消未能及时打断（否则要等满 30s）")
    }

    func testAlreadyCancelledTokenInterruptsImmediately() {
        let token = OpCancellation()
        token.cancel(reason: "pre")
        let started = Date()
        XCTAssertThrowsError(try runBlocking(cancellation: token) {
            try await Task.sleep(for: .seconds(30)); return 1
        })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testTokenIsReusableAfterAnOperationCompletes() throws {
        let token = OpCancellation()
        XCTAssertEqual(try runBlocking(cancellation: token) { 1 }, 1)
        // 上一个任务已结束并 unregister；此时 cancel 不应影响随后（reset 之后）的新任务。
        token.cancel(reason: "sandbox is being stopped")
        token.reset(ifReason: "sandbox is being stopped")
        XCTAssertEqual(try runBlocking(cancellation: token) {
            try await Task.sleep(for: .milliseconds(50)); return 2
        }, 2)
    }

    func testConcurrentCancelAndRegisterNeverLosesCancellation() {
        for _ in 0..<200 {
            let token = OpCancellation()
            let fired = Box(0)
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if i == 0 { token.cancel(reason: "r") } else { token.register { fired.increment() } }
            }
            XCTAssertEqual(fired.value, 1, "cancel 与 register 竞争时丢失了取消")
        }
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int
    init(_ v: Int) { self.v = v }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
    func increment() { lock.lock(); v += 1; lock.unlock() }
}
