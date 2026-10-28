import Combine
import SwiftUI

/// M21：资源统计面板。CPU% 由两次采样差分计算，不做平滑；无数据显示 `—` 而不是 0。
struct StatsPanel: View {
    let client: DaemonSocketClient
    @ObservedObject var viewModel: SandboxViewModel

    @State private var selectedId: String = ""
    @State private var cpuPercent: Double? = nil
    @State private var memCurrent: UInt64? = nil
    @State private var memMax: UInt64? = nil
    @State private var pidsCurrent: Int? = nil
    @State private var pidsMax: Int? = nil
    @State private var activeGroups: Int? = nil
    @State private var statsError: String? = nil
    @State private var history: [Double] = []

    private var sampleTimer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Stats", systemImage: "chart.bar").font(.title3)
                Spacer()
                Picker("sandbox", selection: $selectedId) {
                    Text("—").tag("")
                    ForEach(viewModel.sandboxes, id: \.sandboxId) { sb in
                        Text(sb.sandboxId.prefix(13) + "…").tag(sb.sandboxId)
                    }
                }
                .frame(width: 220)
            }
            .padding(.horizontal)

            if selectedId.isEmpty {
                Text("选择一个沙箱查看资源使用")
                    .font(.callout).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                metricGrid
                sparkline
                if let err = statsError {
                    Text("statsError: \(err)").font(.caption).foregroundColor(.orange)
                        .padding(.horizontal)
                }
                Spacer()
            }
        }
        .padding(.top, 8)
        .onReceive(sampleTimer) { _ in
            if !selectedId.isEmpty { sample() }
        }
    }

    private var metricGrid: some View {
        GridLayout(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                metricLabel("CPU")
                Text(cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                    .font(.system(.title3, design: .monospaced))
            }
            GridRow {
                metricLabel("Memory")
                Text(memPair).font(.system(.title3, design: .monospaced))
            }
            GridRow {
                metricLabel("PIDs")
                Text(pidsPair).font(.system(.title3, design: .monospaced))
            }
            GridRow {
                metricLabel("Active execs")
                Text(activeGroups.map(String.init) ?? "—")
                    .font(.system(.title3, design: .monospaced))
            }
        }
        .padding(.horizontal)
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary).gridColumnAlignment(.trailing)
    }

    private var memPair: String {
        guard let current = memCurrent else { return "—" }
        let cur = formatBytes(current)
        if let max = memMax { return "\(cur) / \(formatBytes(max))" }
        return cur
    }

    private var pidsPair: String {
        guard let current = pidsCurrent else { return "—" }
        if let max = pidsMax { return "\(current) / \(max)" }
        return "\(current)"
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU% (last \(history.count)s)").font(.caption).foregroundColor(.secondary)
            GeometryReader { geo in
                let maxValue = max(history.max() ?? 1, 1)
                Path { path in
                    guard history.count > 1 else { return }
                    let stepX = geo.size.width / CGFloat(max(history.count - 1, 1))
                    for (index, value) in history.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = geo.size.height * (1 - CGFloat(min(value / maxValue, 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            }
            .frame(height: 70)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(4)
        }
        .padding(.horizontal)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / (1024 * 1024)
        if mib >= 1024 { return String(format: "%.2f GiB", mib / 1024) }
        return String(format: "%.1f MiB", mib)
    }

    /// 单次采样：CPU% 用「两次采样差分 / 墙钟时间」。首采样只记录基线。
    private func sample() {
        let sandboxId = selectedId
        let client = self.client
        DispatchQueue.global().async {
            var req = DaemonRequest(kind: "stats")
            req.sandboxId = sandboxId
            guard let resp = try? client.send(req, timeoutSec: 5), let stats = resp.stats else { return }
            DispatchQueue.main.async {
                if let err = stats.statsError { self.statsError = err } else { self.statsError = nil }
                self.memCurrent = stats.memoryCurrentBytes
                self.memMax = stats.memoryMaxBytes
                self.pidsCurrent = stats.pidsCurrent
                self.pidsMax = stats.pidsMax
                self.activeGroups = stats.activeExecGroups

                guard let cpuNow = stats.cpuUsageUsec else {
                    self.cpuPercent = nil
                    return
                }
                let now = DispatchTime.now().uptimeNanoseconds
                defer {
                    self.lastCPUMicros = cpuNow
                    self.lastSampleNanos = now
                }
                guard let lastCPU = self.lastCPUMicros, let lastNanos = self.lastSampleNanos, now > lastNanos else {
                    return
                }
                let deltaCPU = Double(cpuNow &- min(cpuNow, lastCPU))
                let deltaWallMicros = Double(now - lastNanos) / 1000.0
                guard deltaWallMicros > 0 else { return }
                let percent = max(0, min(100.0 * deltaCPU / deltaWallMicros, 100.0 * Double(ProcessInfo.processInfo.activeProcessorCount)))
                self.cpuPercent = percent
                self.history.append(percent)
                if self.history.count > 60 { self.history.removeFirst(self.history.count - 60) }
            }
        }
    }

    @State private var lastCPUMicros: UInt64? = nil
    @State private var lastSampleNanos: UInt64? = nil
}
