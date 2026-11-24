import XCTest
import Foundation
@testable import dbx_poc

/// M26a：引导失败诊断（纯函数）。
final class BootDiagnosticsTests: XCTestCase {

    // MARK: console 特征（文本取自 Linux 内核源码中的字面消息）

    func testClassifiesWellKnownKernelMessages() {
        let cases: [(String, BootFailureKind)] = [
            ("[    0.412345] Initramfs unpacking failed: write error", .outOfMemory),
            ("[    1.2] Out of memory: Killed process 1 (init) total-vm:1234kB", .outOfMemory),
            ("[    1.2] Kernel panic - not syncing: System is deadlocked on memory", .outOfMemory),
            ("[    2.0] VFS: Cannot open root device \"vda\" or unknown-block(0,0): error -6", .rootMountFailed),
            ("[    2.0] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)", .rootMountFailed),
            ("[    2.1] Kernel panic - not syncing: No working init found.  Try passing init= option to kernel.", .initFailed),
            ("[    3.3] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100", .initFailed),
            ("[    0.9] Kernel panic - not syncing: Fatal exception in interrupt", .kernelPanic),
        ]
        for (line, kind) in cases {
            XCTAssertEqual(BootDiagnostics.classify(console: "boot ok\n\(line)\nmore")?.kind, kind, line)
        }
    }

    func testRootCauseBeatsGenericPanicRegardlessOfOrder() {
        // 真实日志里 OOM 之后总会跟一个 panic；必须报根因。
        let log = """
        [ 0.5] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000009
        [ 0.4] Initramfs unpacking failed: write error
        """
        XCTAssertEqual(BootDiagnostics.classify(console: log)?.kind, .outOfMemory)
    }

    func testHealthyBootLogIsNotMisclassified() {
        // 取自本项目 guest 的真实 console 片段。
        let log = """
        [    1.021263] virtio_blk virtio0: 1/0/0 default/read/poll queues
        [    1.021445] virtio_blk virtio0: [vda] 1048576 512-byte logical blocks (537 MB/512 MiB)
        [    1.015298] NET: Registered PF_VSOCK protocol family
        Desk Box initramfs ready
        Desk Box bootstrap: starting
        [    5.100201] random: crng init done
        Desk Box bootstrap: secure channel up
        Desk Box bootstrap: hello sent
        [    0.000000] Memory: 2012345K/2097152K available (init memory freed)
        """
        XCTAssertNil(BootDiagnostics.classify(console: log))
        XCTAssertNil(BootDiagnostics.classify(console: ""))
        XCTAssertNil(BootDiagnostics.classify(console: Data([0xFF, 0xFE, 0x00, 0x80])))
    }

    func testMatchingIsCaseInsensitiveAndHandlesCRLF() {
        XCTAssertEqual(BootDiagnostics.classify(console: "x\r\nKERNEL PANIC - NOT SYNCING: boom\r\n")?.kind, .kernelPanic)
    }

    // MARK: 净化（console 由 guest 控制）

    func testEvidenceIsSanitized() {
        let hostile = "\u{1B}[31mKernel panic\u{1B}[0m - not syncing:\u{07}\u{00} x\u{1B}]0;title\u{07}\ty"
        let d = BootDiagnostics.classify(console: hostile)
        XCTAssertEqual(d?.kind, .kernelPanic)
        let evidence = d?.evidence ?? ""
        XCTAssertFalse(evidence.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, evidence)
        XCTAssertFalse(evidence.contains("\u{1B}"))
        XCTAssertTrue(evidence.hasPrefix("Kernel panic - not syncing:"), evidence)
    }

    func testEvidenceAndTailAreBounded() {
        let long = "Kernel panic " + String(repeating: "A", count: 5000)
        XCTAssertLessThanOrEqual(BootDiagnostics.classify(console: long)!.evidence.count, 201)
        let tail = BootDiagnostics.tailSummary(console: Data(String(repeating: "line \(String(repeating: "B", count: 400))\n", count: 50).utf8))
        XCTAssertLessThanOrEqual(tail.count, 301)
    }

    func testTailSummary() {
        XCTAssertEqual(BootDiagnostics.tailSummary(console: Data()), "<no console output>")
        XCTAssertEqual(BootDiagnostics.tailSummary(console: Data("\n\r\n \n".utf8)), "<no console output>")
        XCTAssertEqual(BootDiagnostics.tailSummary(console: Data("a\nb\nc\nd\n".utf8)), "b ⏎ c ⏎ d")
        // C1 控制字符（0x80–0x9F，含 8-bit CSI 0x9B）同样被剔除。
        XCTAssertEqual(BootDiagnostics.sanitize("a\u{9B}31mb\u{85}c", limit: 50), "a 31mb c")
    }

    func testMessageCarriesStableReasonCode() {
        let d = BootDiagnostics.classify(console: "Kernel panic - not syncing: VFS: Unable to mount root fs")!
        XCTAssertTrue(d.message.hasPrefix("DBX-BOOT-FAILED(root-mount-failed): "), d.message)
        XCTAssertTrue(d.message.contains("| console: Kernel panic"), d.message)
        XCTAssertEqual(Set(BootFailureKind.allCases.map(\.rawValue)),
                       ["out-of-memory", "root-mount-failed", "init-failed", "kernel-panic", "no-console-output"])
    }

    // MARK: 静默引导

    private let alpine = BootMemoryEstimate(kernelBytes: 32_956_352, initrdCompressedBytes: 99_376_100,
                                            initrdUnpackedBytes: 337_103_872)

    func testEstimateMatchesCalibration() {
        // 实测：568MiB 可引导、560MiB 不可。估算必须落在「不低于实测下限、且不离谱」的区间。
        XCTAssertEqual(alpine.estimatedMinimumMiB, 576)
        XCTAssertEqual(alpine.initrdUnpackedMiB, 322)
        XCTAssertGreaterThanOrEqual(alpine.estimatedMinimumMiB, 561)
        XCTAssertLessThan(alpine.estimatedMinimumMiB, 640)
    }

    func testSilenceNotDiagnosedBeforeThreshold() {
        XCTAssertNil(BootDiagnostics.diagnoseSilence(elapsed: 9.9, silenceSeconds: 10, memoryMiB: 512, estimate: alpine))
        XCTAssertNotNil(BootDiagnostics.diagnoseSilence(elapsed: 10, silenceSeconds: 10, memoryMiB: 512, estimate: alpine))
    }

    func testSilenceBelowEstimateNamesMemory() {
        let d = BootDiagnostics.diagnoseSilence(elapsed: 11, silenceSeconds: 10, memoryMiB: 512, estimate: alpine)!
        XCTAssertEqual(d.kind, .noConsoleOutput)
        XCTAssertTrue(d.message.hasPrefix("DBX-BOOT-FAILED(no-console-output): "), d.message)
        XCTAssertTrue(d.message.contains("内存 512MiB 低于"), d.message)
        XCTAssertTrue(d.message.contains("576MiB"), d.message)
        XCTAssertTrue(d.message.contains("--memory-mib"), d.message)
        XCTAssertFalse(d.message.contains("console: "), "静默场景没有 console 可引用")
    }

    func testSilenceAtOrAboveEstimateDoesNotBlameMemory() {
        for mem in [576, 2048] {
            let d = BootDiagnostics.diagnoseSilence(elapsed: 11, silenceSeconds: 10, memoryMiB: mem, estimate: alpine)!
            XCTAssertTrue(d.message.contains("不低于估算下限"), d.message)
            XCTAssertTrue(d.message.contains("损坏或不匹配"), d.message)
        }
    }

    func testSilenceWithUnknownEstimateSaysSo() {
        let d = BootDiagnostics.diagnoseSilence(elapsed: 11, silenceSeconds: 10, memoryMiB: 2048, estimate: nil)!
        XCTAssertTrue(d.message.contains("无法估算"), d.message)
        XCTAssertFalse(d.message.contains("低于该 guest"), d.message)
    }

    // MARK: gzip ISIZE

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-gz-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fakeGzip(body: Int, isize: UInt32) -> [UInt8] {
        [0x1F, 0x8B] + [UInt8](repeating: 0x55, count: body)
            + [UInt8(isize & 0xFF), UInt8((isize >> 8) & 0xFF), UInt8((isize >> 16) & 0xFF), UInt8(isize >> 24)]
    }

    func testGzipUnpackedSizeReadsTrailer() throws {
        let bytes = fakeGzip(body: 100, isize: 337_103_872)
        let url = try tempFile(bytes)
        XCTAssertEqual(BootMemoryEstimate.gzipUnpackedSize(of: url, compressedSize: UInt64(bytes.count)), 337_103_872)
    }

    func testGzipUnpackedSizeRejectsUntrustworthyInputs() throws {
        // 非 gzip
        let plain = [UInt8](repeating: 0x30, count: 64)
        XCTAssertNil(BootMemoryEstimate.gzipUnpackedSize(of: try tempFile(plain), compressedSize: 64))
        // ISIZE 小于压缩尺寸（回绕 / 多成员）
        let wrapped = fakeGzip(body: 100, isize: 10)
        XCTAssertNil(BootMemoryEstimate.gzipUnpackedSize(of: try tempFile(wrapped), compressedSize: UInt64(wrapped.count)))
        // 太短
        XCTAssertNil(BootMemoryEstimate.gzipUnpackedSize(of: try tempFile([0x1F, 0x8B, 0, 0]), compressedSize: 4))
        // 文件不存在
        XCTAssertNil(BootMemoryEstimate.gzipUnpackedSize(of: URL(fileURLWithPath: "/nonexistent/dbx"), compressedSize: 100))
        XCTAssertNil(BootMemoryEstimate.measure(kernelURL: URL(fileURLWithPath: "/nonexistent/k"), initrdURL: nil))
    }

    func testMeasureReadsRealFiles() throws {
        let initrd = fakeGzip(body: 1000, isize: 50_000)
        let kernel = [UInt8](repeating: 1, count: 2048)
        let e = BootMemoryEstimate.measure(kernelURL: try tempFile(kernel), initrdURL: try tempFile(initrd))
        XCTAssertEqual(e, BootMemoryEstimate(kernelBytes: 2048, initrdCompressedBytes: UInt64(initrd.count), initrdUnpackedBytes: 50_000))
        XCTAssertEqual(e?.estimatedMinimumMiB, 129)   // <1MiB 向上取整 + 128 余量
    }

    // MARK: 环境变量旋钮（越界/非法一律回落默认，不接受 0 或负数把等待变成忙等/永久）

    func testBootKnobsValidateRange() {
        XCTAssertEqual(SandboxDaemon.bootTimeoutSeconds(environment: [:]), 90)
        XCTAssertEqual(SandboxDaemon.bootTimeoutSeconds(environment: ["DBX_BOOT_TIMEOUT_SECONDS": "15"]), 15)
        for bad in ["0", "4", "601", "-1", "abc", "", "1e2", " 30"] {
            XCTAssertEqual(SandboxDaemon.bootTimeoutSeconds(environment: ["DBX_BOOT_TIMEOUT_SECONDS": bad]), 90, bad)
        }
        XCTAssertEqual(SandboxDaemon.bootSilenceSeconds(environment: [:]), 10)
        XCTAssertEqual(SandboxDaemon.bootSilenceSeconds(environment: ["DBX_BOOT_SILENCE_SECONDS": "30"]), 30)
        for bad in ["0", "1", "121", "-5", "x"] {
            XCTAssertEqual(SandboxDaemon.bootSilenceSeconds(environment: ["DBX_BOOT_SILENCE_SECONDS": bad]), 10, bad)
        }
    }
}
