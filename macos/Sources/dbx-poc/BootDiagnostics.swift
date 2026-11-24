import Foundation

/// M26a：引导失败快速诊断（纯函数，可单元测试）。
///
/// 输入是 guest serial console 的尾部文本。console **由 guest 控制、只作诊断**：
/// - 它只能让「正在引导的这台沙箱」更早失败（guest 伪造 panic 文本 = 拒绝自己的服务），
///   永远不能让引导成功——readiness 仍然只认已认证的 bootstrap 握手；
/// - 进入错误消息前会被净化（去控制字符、限长），不让 guest 往宿主终端/日志里注入转义序列。
/// 引导所需内存的**经验估算**（仅用于错误提示，绝不用于拒绝请求）。
///
/// 依据：内核把 gzip initramfs 解包进内存时，压缩镜像、解包后的内容与内核本身同时驻留。
/// 估算 = kernel + initrd(压缩) + initrd(解包) + 128MiB 余量。
/// 校准（Alpine guest，kernel 31MiB / initrd 95MiB→322MiB）：估算 576MiB，实测 568MiB 可引导、
/// 560MiB 不可。只有一个 guest 的数据点，所以它是提示而不是闸门。
struct BootMemoryEstimate: Sendable, Equatable {
    let kernelBytes: UInt64
    let initrdCompressedBytes: UInt64
    let initrdUnpackedBytes: UInt64

    static let reserveMiB: UInt64 = 128

    var estimatedMinimumMiB: Int {
        let total = kernelBytes + initrdCompressedBytes + initrdUnpackedBytes
        return Int((total + 1_048_575) / 1_048_576 + Self.reserveMiB)
    }

    var initrdUnpackedMiB: Int { Int((initrdUnpackedBytes + 1_048_575) / 1_048_576) }

    /// 读取 kernel / initrd 尺寸。initrd 不是单成员 gzip（或 ISIZE 不可信）时返回 nil：
    /// 宁可不给提示，也不给错的。
    static func measure(kernelURL: URL, initrdURL: URL?) -> BootMemoryEstimate? {
        let fm = FileManager.default
        guard let initrdURL,
              let kernelSize = (try? fm.attributesOfItem(atPath: kernelURL.path)[.size]) as? UInt64,
              let initrdSize = (try? fm.attributesOfItem(atPath: initrdURL.path)[.size]) as? UInt64,
              let unpacked = gzipUnpackedSize(of: initrdURL, compressedSize: initrdSize) else { return nil }
        return BootMemoryEstimate(kernelBytes: kernelSize, initrdCompressedBytes: initrdSize,
                                  initrdUnpackedBytes: unpacked)
    }

    /// gzip 尾部 ISIZE（解包长度 mod 2^32，小端）。只在「看起来可信」时采用：
    /// 有 gzip 魔数，且 ISIZE 不小于压缩尺寸（否则多半是回绕或多成员拼接）。
    static func gzipUnpackedSize(of url: URL, compressedSize: UInt64) -> UInt64? {
        guard compressedSize >= 18, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 2), magic.count == 2,
              magic[magic.startIndex] == 0x1F, magic[magic.startIndex + 1] == 0x8B else { return nil }
        guard (try? handle.seek(toOffset: compressedSize - 4)) != nil,
              let tail = try? handle.read(upToCount: 4), tail.count == 4 else { return nil }
        let b = [UInt8](tail)
        let isize = UInt64(b[0]) | UInt64(b[1]) << 8 | UInt64(b[2]) << 16 | UInt64(b[3]) << 24
        return isize >= compressedSize ? isize : nil
    }
}

enum BootFailureKind: String, Sendable, CaseIterable {
    /// 内存不足以解包 initramfs / 启动 init。
    case outOfMemory = "out-of-memory"
    /// 根文件系统挂载失败。
    case rootMountFailed = "root-mount-failed"
    /// init 缺失或立即退出。
    case initFailed = "init-failed"
    /// 其它内核 panic。
    case kernelPanic = "kernel-panic"
    /// 限定时间内 console 没有任何输出：guest 在 console 就绪之前就已死亡。
    case noConsoleOutput = "no-console-output"
}

struct BootDiagnosis: Sendable, Equatable {
    let kind: BootFailureKind
    /// 命中的那一行 console（已净化）。
    let evidence: String

    var hint: String {
        switch kind {
        case .outOfMemory: return "guest 内存不足以完成引导；调大 --memory-mib"
        case .rootMountFailed: return "guest 无法挂载根文件系统；检查 manifest 的 rootfs/内核是否匹配"
        case .initFailed: return "guest init 无法启动或立即退出；检查 rootfs 内的 /init"
        case .kernelPanic: return "guest 内核 panic；见 console"
        case .noConsoleOutput: return "guest 在 console 就绪前已停止运行"
        }
    }

    /// 稳定的原因码前缀（CLI / e2e 可 grep）。
    var message: String {
        // no-console-output 没有 console 可引用，evidence 是判定依据本身。
        let label = kind == .noConsoleOutput ? "" : "console: "
        return "DBX-BOOT-FAILED(\(kind.rawValue)): \(hint) | \(label)\(evidence)"
    }
}

enum BootDiagnostics {
    /// 按「越具体越优先」排序；同一段 console 里 OOM 往往最终也表现为 panic，
    /// 必须先报根因。匹配不区分大小写。
    private static let rules: [(BootFailureKind, [String])] = [
        (.outOfMemory, [
            "out of memory",
            "initramfs unpacking failed",
            "cannot allocate memory",
            "system is deadlocked on memory",
            "page allocation failure",
        ]),
        (.rootMountFailed, [
            "vfs: unable to mount root",
            "vfs: cannot open root device",
            "unable to mount root fs",
        ]),
        (.initFailed, [
            "no working init found",
            "attempted to kill init",
            "failed to execute /init",
            "requested init /init failed",
        ]),
        (.kernelPanic, [
            "kernel panic",
        ]),
    ]

    /// 在 console 文本里找引导失败的根因；没有已知特征返回 nil（继续等待）。
    static func classify(console: String) -> BootDiagnosis? {
        let lines = console.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        for (kind, needles) in rules {
            for line in lines {
                let lower = line.lowercased()
                if needles.contains(where: { lower.contains($0) }) {
                    return BootDiagnosis(kind: kind, evidence: sanitize(line, limit: 200))
                }
            }
        }
        return nil
    }

    static func classify(console: Data) -> BootDiagnosis? {
        classify(console: String(decoding: console, as: UTF8.self))
    }

    /// 「静默引导」判定：在 `silenceSeconds` 内 console 一个字节都没有。
    ///
    /// 为什么需要它：本项目的 guest 把 virtio console 驱动放在 initramfs 里，initramfs 解包
    /// 失败（典型原因：内存不足）时内核连一行都打不出来，console 特征匹配无从谈起。
    /// 健康引导的首字节实测约 1.2s（4 台并行引导时亦然），阈值默认 10s。
    static func diagnoseSilence(elapsed: TimeInterval, silenceSeconds: TimeInterval,
                                memoryMiB: Int, estimate: BootMemoryEstimate?) -> BootDiagnosis? {
        guard elapsed >= silenceSeconds else { return nil }
        let evidence: String
        if let estimate, memoryMiB < estimate.estimatedMinimumMiB {
            evidence = "\(Int(silenceSeconds))s 内无任何输出；内存 \(memoryMiB)MiB 低于该 guest 的估算下限约 "
                + "\(estimate.estimatedMinimumMiB)MiB（initrd 解包后 \(estimate.initrdUnpackedMiB)MiB），请调大 --memory-mib"
        } else if let estimate {
            evidence = "\(Int(silenceSeconds))s 内无任何输出；内存 \(memoryMiB)MiB 不低于估算下限约 "
                + "\(estimate.estimatedMinimumMiB)MiB，更可能是 kernel/initrd 损坏或不匹配"
        } else {
            evidence = "\(Int(silenceSeconds))s 内无任何输出；无法估算该 guest 的内存下限（initrd 不是单成员 gzip），"
                + "请检查 kernel/initrd 是否损坏或不匹配，或调大 --memory-mib"
        }
        return BootDiagnosis(kind: .noConsoleOutput, evidence: evidence)
    }

    /// 超时等「没有已知特征」的场景：给出最后几行 console 作线索。
    static func tailSummary(console: Data, maxLines: Int = 3, limit: Int = 300) -> String {
        let text = String(decoding: console, as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { sanitize(String($0), limit: limit) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "<no console output>" }
        return sanitize(lines.suffix(maxLines).joined(separator: " ⏎ "), limit: limit)
    }

    /// 去掉 ANSI 转义序列与全部控制字符（含 ESC / BEL / NUL），折叠空白，限长。
    static func sanitize(_ raw: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        var scalars = raw.unicodeScalars.makeIterator()
        var pendingSpace = false
        while let s = scalars.next() {
            if s == "\u{1B}" {
                // CSI：ESC [ … <final byte @–~>；其它 ESC 序列丢弃后一个字符。
                guard let next = scalars.next() else { break }
                if next == "[" {
                    while let c = scalars.next() {
                        if c.value >= 0x40 && c.value <= 0x7E { break }
                    }
                }
                continue
            }
            let isControl = s.value < 0x20 || s.value == 0x7F || (s.value >= 0x80 && s.value < 0xA0)
            if isControl || s == " " {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(s)
        }
        var result = String(out)
        if result.count > limit { result = String(result.prefix(limit)) + "…" }
        return result
    }
}
