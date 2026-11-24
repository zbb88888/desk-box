import Combine
import SwiftUI

/// M21：资源统计面板。CPU% 由两次采样差分计算，不做平滑；无数据显示 `—` 而不是 0。
struct StatsPanel: View {
    let client: DaemonSocketClient
    @ObservedObject var viewModel: SandboxViewModel

    @State private var selectedId: String = ""
    /// M33：数据与采样逻辑在 StatsModel（切换沙箱重置基线、丢弃迟到响应、失败可见）。
    @StateObject private var model: StatsModel

    init(client: DaemonSocketClient, viewModel: SandboxViewModel) {
        self.client = client
        self.viewModel = viewModel
        _model = StateObject(wrappedValue: StatsModel(client: client))
    }

    private var cpuPercent: Double? { model.cpuPercent }
    private var memCurrent: UInt64? { model.memCurrent }
    private var memMax: UInt64? { model.memMax }
    private var pidsCurrent: Int? { model.pidsCurrent }
    private var pidsMax: Int? { model.pidsMax }
    private var activeGroups: Int? { model.activeGroups }
    private var statsError: String? { model.statsError }
    private var history: [Double] { model.history }

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
                    Text(err).font(.caption).foregroundColor(.orange)
                        .padding(.horizontal)
                }
                Spacer()
            }
        }
        .padding(.top, 8)
        .onChange(of: selectedId) { _, newValue in model.select(newValue) }
        .onReceive(sampleTimer) { _ in
            // 选中的沙箱已经不在列表里（被移除）：回到未选择状态，而不是对着一个不存在的 id 轮询。
            // 只在列表刷新成功时判断：daemon 一时不可达会让列表暂时为空，不应因此丢掉选择。
            if !selectedId.isEmpty, viewModel.errorText == nil,
               !viewModel.sandboxes.contains(where: { $0.sandboxId == selectedId }) {
                selectedId = ""
            }
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

    private func sample() { model.sample() }
}
