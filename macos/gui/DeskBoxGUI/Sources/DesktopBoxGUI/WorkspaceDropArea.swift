import SwiftUI
import UniformTypeIdentifiers

/// M15：drag&drop workspace → wsSync 到指定沙箱。
struct WorkspaceDropView: View {
    let client: DaemonSocketClient
    @State private var sandboxId: String = ""
    @State private var status: String = "drag a folder here"
    @State private var hovering: Bool = false
    @State private var lastPath: String = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("sandbox id", text: $sandboxId).textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(.horizontal)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundColor(hovering ? .blue : .secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(hovering ? Color.blue.opacity(0.08) : Color.clear)
                    )

                VStack(spacing: 6) {
                    Image(systemName: "folder.fill.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    if !lastPath.isEmpty {
                        Text(lastPath)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(24)
            }
            .padding()
            .onDrop(of: [.fileURL], isTargeted: $hovering, perform: handleDrop)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !sandboxId.isEmpty else {
            status = "先填 sandbox id"
            return false
        }
        var found = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = item as? URL ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) })
                    else { return }
                    DispatchQueue.main.async {
                        self.lastPath = url.path
                        self.syncFolder(url.path)
                    }
                }
                found = true
            }
        }
        return found
    }

    private func syncFolder(_ path: String) {
        var req = DaemonRequest(kind: "wsSync")
        req.sandboxId = sandboxId
        req.workspaceDir = path
        DispatchQueue.global().async {
            do {
                let response = try self.client.send(req)
                DispatchQueue.main.async {
                    self.status = response.stdout ?? "ws-sync ok"
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "sync failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
