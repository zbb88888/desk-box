import Foundation

/// M33：CPU% = 两次采样的 CPU 时间差 / 墙钟时间差（纯计算，可单元测试）。
struct CPUPercentCalculator {
    private var lastCPUMicros: UInt64?
    private var lastNanos: UInt64?

    mutating func reset() { lastCPUMicros = nil; lastNanos = nil }

    /// - Returns: 百分比（多核可超过 100，上限 100 × cores）；首个样本、计数器不可用、
    ///   计数器回退（guest 重启）或时钟未前进时返回 nil，并以当前样本重新建立基线——
    ///   不伪造一个 0%。
    mutating func next(cpuUsageMicros: UInt64?, nowNanos: UInt64, cores: Int) -> Double? {
        guard let cpuNow = cpuUsageMicros else { reset(); return nil }
        defer { lastCPUMicros = cpuNow; lastNanos = nowNanos }
        guard let lastCPU = lastCPUMicros, let last = lastNanos, nowNanos > last, cpuNow >= lastCPU else { return nil }
        let wallMicros = Double(nowNanos - last) / 1000.0
        guard wallMicros > 0 else { return nil }
        let percent = 100.0 * Double(cpuNow - lastCPU) / wallMicros
        return max(0, min(percent, 100.0 * Double(max(cores, 1))))
    }
}

/// M33：Stats 面板的状态（此前是 StatsPanel 里的一堆 @State + 视图内的采样函数）。
///
/// 修掉的问题：
/// - 切换沙箱不重置基线：切换后的第一个 CPU% 是用「另一个沙箱的计数器」算出来的；
/// - 旧选择的迟到响应会覆盖新选择的数据；
/// - 采样失败被静默忽略：沙箱没了以后，界面永远停在最后一组数字上。
final class StatsModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memCurrent: UInt64?
    @Published private(set) var memMax: UInt64?
    @Published private(set) var pidsCurrent: Int?
    @Published private(set) var pidsMax: Int?
    @Published private(set) var activeGroups: Int?
    @Published private(set) var statsError: String?
    @Published private(set) var history: [Double] = []

    static let historyLimit = 60

    private let client: DaemonSocketClient
    private(set) var selectedId = ""
    /// 每次切换选择 +1；带着旧代号回来的响应一律丢弃。
    private var generation = 0
    private var calculator = CPUPercentCalculator()

    init(client: DaemonSocketClient) { self.client = client }

    /// 切换沙箱（主线程）。清空所有数据与 CPU 基线。
    func select(_ sandboxId: String) {
        guard sandboxId != selectedId else { return }
        selectedId = sandboxId
        generation += 1
        calculator.reset()
        cpuPercent = nil; memCurrent = nil; memMax = nil
        pidsCurrent = nil; pidsMax = nil; activeGroups = nil
        statsError = nil
        history = []
    }

    /// 采一次样（主线程调用；I/O 在后台）。
    func sample(completion: (@MainActor @Sendable () -> Void)? = nil) {
        let sandboxId = selectedId
        guard !sandboxId.isEmpty else { completion.map { c in MainActor.assumeIsolated { c() } }; return }
        let client = self.client
        let issued = generation
        DispatchQueue.global().async {
            var request = DaemonRequest(kind: "stats")
            request.sandboxId = sandboxId
            let result: Result<DaemonResponse, Error>
            do { result = .success(try client.send(request, timeoutSec: 5)) }
            catch { result = .failure(error) }
            let now = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if issued == self.generation {
                        self.apply(result, nowNanos: now, cores: ProcessInfo.processInfo.activeProcessorCount)
                    }
                    completion?()
                }
            }
        }
    }

    /// 把一次采样结果写入状态（拆出来便于单测）。
    func apply(_ result: Result<DaemonResponse, Error>, nowNanos: UInt64, cores: Int) {
        switch result {
        case .failure(let error):
            // 不保留旧数字：它们已经不代表当前状态。
            clearMetrics()
            statsError = DaemonErrorPresenter.present(error).logLine
        case .success(let response):
            guard let stats = response.stats else {
                clearMetrics()
                statsError = "daemon 没有返回统计数据"
                return
            }
            statsError = stats.statsError
            memCurrent = stats.memoryCurrentBytes
            memMax = stats.memoryMaxBytes
            pidsCurrent = stats.pidsCurrent
            pidsMax = stats.pidsMax
            activeGroups = stats.activeExecGroups
            cpuPercent = calculator.next(cpuUsageMicros: stats.cpuUsageUsec, nowNanos: nowNanos, cores: cores)
            if let percent = cpuPercent {
                history.append(percent)
                if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
            }
        }
    }

    private func clearMetrics() {
        calculator.reset()
        cpuPercent = nil; memCurrent = nil; memMax = nil
        pidsCurrent = nil; pidsMax = nil; activeGroups = nil
    }
}

/// M33：workspace 同步（Settings 的「Sync to /workspace」与拖放区共用）。
enum WorkspaceSync {
    /// 本地前置检查；返回 nil 表示可以发给 daemon。
    static func precheck(sandboxId: String, path: String) -> String? {
        if sandboxId.trimmingCharacters(in: .whitespaces).isEmpty { return "先填 sandbox id" }
        if path.isEmpty { return "先选择 workspace 目录" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "目录不存在：\(path)" }
        guard isDirectory.boolValue else { return "不是目录：\(path)" }
        return nil
    }

    /// - Parameter completion: (状态文本, 是否成功)，在主线程回调。
    static func sync(client: DaemonSocketClient, sandboxId: String, path: String,
                     completion: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        if let problem = precheck(sandboxId: sandboxId, path: path) {
            MainActor.assumeIsolated { completion(problem, false) }
            return
        }
        var request = DaemonRequest(kind: "wsSync")
        request.sandboxId = sandboxId.trimmingCharacters(in: .whitespaces)
        request.workspaceDir = path
        let outgoing = request
        DispatchQueue.global().async {
            let text: String
            let ok: Bool
            do {
                let response = try client.send(outgoing, timeoutSec: SandboxViewModel.timeoutSeconds(forKind: "wsSync"))
                text = response.stdout ?? "ws-sync ok"; ok = true
            } catch {
                text = DaemonErrorPresenter.present(error).logLine; ok = false
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(text, ok) } }
        }
    }
}
