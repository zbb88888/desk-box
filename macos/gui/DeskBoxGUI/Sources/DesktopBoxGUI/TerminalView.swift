import SwiftUI

final class PtySessionModel: ObservableObject, @unchecked Sendable {
    @Published var output: String = ""
    @Published var running: Bool = false
    @Published var sessionId: String?
    @Published var error: String? = nil

    private let sandboxId: String
    private let client: DaemonSocketClient
    private var timer: Timer?
    /// M33：有状态的输出净化（转义序列 / 多字节字符可能跨 poll 切开）。
    private var filter = TerminalTextFilter()
    /// 上一次 poll 还没回来就不再发下一次（否则 daemon 一慢，请求会越积越多）。
    private var pollInFlight = false

    init(sandboxId: String, client: DaemonSocketClient) {
        self.sandboxId = sandboxId
        self.client = client
    }

    func open() {
        DispatchQueue.global().async {
            do {
                var req = DaemonRequest(kind: "ptyOpen")
                req.sandboxId = self.sandboxId
                req.argv = ["/bin/sh"]
                let response = try self.client.send(req)
                DispatchQueue.main.async {
                    self.sessionId = response.ptySessionId
                    self.running = true
                    self.startPolling()
                }
            } catch {
                let line = DaemonErrorPresenter.present(error).logLine
                DispatchQueue.main.async { self.error = line }
            }
        }
    }

    func close() {
        if let sid = sessionId {
            let client = self.client
            DispatchQueue.global().async {
                var req = DaemonRequest(kind: "ptyClose")
                req.ptySessionId = sid
                // daemon 会等 guest 确认 shell 已退出（最多 2s），客户端要等得更久一点。
                _ = try? client.send(req, timeoutSec: 5)
            }
        }
        timer?.invalidate()
        timer = nil
        running = false
    }

    func sendRawHex(_ hex: String) {
        guard let sid = sessionId else { return }
        let client = self.client
        DispatchQueue.global().async {
            var req = DaemonRequest(kind: "ptyInput")
            req.ptySessionId = sid
            req.dataHex = hex
            _ = try? client.send(req, timeoutSec: 5)
        }
    }

    func sendInput(_ text: String) {
        guard let sid = sessionId else { return }
        var bytes = Data(text.utf8)
        if !text.isEmpty && text.last != "\n" { bytes.append(0x0A) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let client = self.client
        DispatchQueue.global().async {
            var req = DaemonRequest(kind: "ptyInput")
            req.ptySessionId = sid
            req.dataHex = hex
            _ = try? client.send(req, timeoutSec: 5)
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }

    private func pollOnce() {
        guard let sid = sessionId, !pollInFlight else { return }
        pollInFlight = true
        let client = self.client
        DispatchQueue.global().async {
            let result: Result<DaemonResponse, Error>
            do {
                var req = DaemonRequest(kind: "ptyPoll")
                req.ptySessionId = sid
                req.waitMillis = 120
                result = .success(try client.send(req, timeoutSec: 3))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                self.pollInFlight = false
                self.handlePoll(result)
            }
        }
    }

    /// 处理一次 poll 的结果（主线程；拆出来便于单测）。
    func handlePoll(_ result: Result<DaemonResponse, Error>) {
        switch result {
        case .success(let response):
            if let hex = response.outputHex, !hex.isEmpty {
                // M33：畸形 hex 不再崩溃（此前的手写解码在奇数长度时越界）。
                if let data = HexCoding.decode(hex) { filter.feed(data, into: &output) }
                else { error = "daemon 返回了无法解码的输出（已忽略 \(hex.count) 个字符）" }
            }
            if response.running == false {
                running = false
                output += "\n[pty exited code=\(response.exitCode ?? 0)]"
                timer?.invalidate()
            }
        case .failure(let failure):
            running = false
            error = "poll: \(DaemonErrorPresenter.present(failure).logLine)"
            timer?.invalidate()
        }
    }
}

struct TerminalView: View {
    let sandboxId: String
    let client: DaemonSocketClient
    @StateObject private var model: PtySessionModel
    @State private var input: String = ""

    init(sandboxId: String, client: DaemonSocketClient) {
        self.sandboxId = sandboxId
        self.client = client
        _model = StateObject(wrappedValue: PtySessionModel(sandboxId: sandboxId, client: client))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PTY: \(sandboxId.prefix(18))").font(.caption)
                Circle().fill(model.running ? Color.green : Color.red).frame(width: 8, height: 8)
                Spacer()
                Button("Close") { model.close() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("out")
                }
                .background(Color(NSColor.black))
                .foregroundColor(.green)
                .cornerRadius(4)
                .onChange(of: model.output) { _ in proxy.scrollTo("out", anchor: .bottom) }
            }
            HStack {
                TextField("type command…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.sendInput(input); input = "" }
                Button("Send") { model.sendInput(input); input = "" }
                // M15：純交互 Ctrl+C-EMPTY
                Button("Ctrl+C") { model.sendRawHex("03") }
            }
            if let err = model.error { Text(err).foregroundColor(.red).font(.caption) }
        }
        .padding()
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }
}
