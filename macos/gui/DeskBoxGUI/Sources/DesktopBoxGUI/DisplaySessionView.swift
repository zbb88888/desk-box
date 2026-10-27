import SwiftUI
import Virtualization

/// M14c：display session window — 真实 virtio-gpu framebuffer 出到 GSView。
struct DisplaySessionView: View {
    @ObservedObject var model: DisplaySandboxViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Desk Box Guest Display").font(.headline)
                Spacer()
                Text(model.status).font(.caption).foregroundColor(.orange)
                Button("Stop") { model.stop() }
                    .disabled(model.machine == nil)
            }
            .padding(.horizontal)

            if let machine = model.machine {
                NSViewWrapper(machine: machine)
                    .frame(minWidth: 1280 / 1.25, minHeight: 800 / 1.25)
                    .cornerRadius(6)
                    .padding(.horizontal)
            } else {
                Text(model.busy ? "Booting…" : "Display sandbox 未启动")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
            Divider()
            Text("virtio-gpu (fb0) → VZVirtualMachineView；keyboard/mouse 发生转发由 VZ 提供。rootfs 的 fbcon getty 设定 会随获得rootfs rebuild 激活。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding(.vertical)
        .frame(minWidth: 800, minHeight: 520)
    }
}

private struct NSViewWrapper: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = machine
    }
}
