import XCTest
import Foundation
@testable import dbx_poc

/// M27：resume 失败诊断。
final class ResumeDiagnosticsTests: XCTestCase {
    /// 真机上抓到的原始错误文本。
    private let vzRestore = "Error Domain=VZErrorDomain Code=12 \"The virtual machine failed to restore with error “permission denied”.\" UserInfo={NSLocalizedFailure=An error occurred while restoring the virtual machine., NSLocalizedFailureReason=The virtual machine failed to restore with error “permission denied”.}"

    func testLockedSessionIsNamedAsTheCause() {
        let m = ResumeDiagnostics.explain(errorDescription: vzRestore, screenLocked: true)
        XCTAssertNotNil(m)
        XCTAssertTrue(m!.hasPrefix("DBX-RESUME-HOST-LOCKED: "), m!)
        XCTAssertTrue(m!.contains("锁屏"), m!)
        XCTAssertTrue(m!.contains("解锁后重试"), m!)
        XCTAssertTrue(m!.contains("快照已保留"), m!)
        XCTAssertTrue(m!.contains("underlying: Error Domain=VZErrorDomain Code=12"), "必须保留原始错误供排查：\(m!)")
    }

    func testUnlockedSessionDoesNotBlameTheLock() {
        let m = ResumeDiagnostics.explain(errorDescription: vzRestore, screenLocked: false)!
        XCTAssertTrue(m.hasPrefix("DBX-RESUME-VZ-RESTORE-FAILED: "), m)
        XCTAssertTrue(m.contains("会话未锁屏"), m)
        XCTAssertFalse(m.contains("DBX-RESUME-HOST-LOCKED"), m)
    }

    func testUnknownSessionStateIsReportedAsUnknown() {
        let m = ResumeDiagnostics.explain(errorDescription: vzRestore, screenLocked: nil)!
        XCTAssertTrue(m.hasPrefix("DBX-RESUME-VZ-RESTORE-FAILED: "), m)
        XCTAssertTrue(m.contains("无法判断会话是否锁屏"), m)
    }

    func testOtherErrorsAreLeftUntouched() {
        // 我们自己的闸门（解密失败 / 域不符 / 状态非法）必须原样上抛，不能被改写成「锁屏」。
        for other in [
            "快照解密/完整性校验失败（密文、metadata 或 key 不符）",
            "DBX-LIFECYCLE-INVALID-TRANSITION: resume 仅允许 suspended 状态",
            "snapshot-domain-mismatch",
            "Error Domain=VZErrorDomain Code=1 \"Internal Virtualization error.\"",
            "Error Domain=NSPOSIXErrorDomain Code=12 \"Cannot allocate memory\"",
            "",
        ] {
            XCTAssertNil(ResumeDiagnostics.explain(errorDescription: other, screenLocked: true), other)
        }
    }

    func testUnderlyingIsSanitizedAndBounded() {
        let hostile = vzRestore + "\u{1B}[31m" + String(repeating: "X", count: 2000) + "\u{07}"
        let m = ResumeDiagnostics.explain(errorDescription: hostile, screenLocked: true)!
        XCTAssertFalse(m.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "含控制字符")
        XCTAssertLessThan(m.count, 600)
    }

    func testHostSessionProbeDoesNotCrash() {
        // 取值取决于运行环境（锁屏 / 未锁屏 / 无 GUI 会话），只要求调用安全且结果自洽。
        let a = HostSession.isScreenLocked()
        let b = HostSession.isScreenLocked()
        XCTAssertEqual(a, b)
    }
}
