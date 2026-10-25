import SwiftUI

final class PtySessionModel: ObservableObject, @unchecked Sendable {
    @Published var output: String = ""
    @Published var running: Bool = false
    @Published var sessionId: String?
    @Published var error: String? = nil

    private let sandboxId: String
    private let client: DaemonSocketClient
    private var timer: Timer?

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
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    func close() {
        if let sid = sessionId {
            let client = self.client
            DispatchQueue.global().async {
                var req = DaemonRequest(kind: "ptyClose")
                req.ptySessionId = sid
                _ = try? client.send(req, timeoutSec: 2)
            }
        }
        timer?.invalidate()
        timer = nil
        running = false
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
        guard let sid = sessionId else { return }
        let client = self.client
        DispatchQueue.global().async {
            do {
                var req = DaemonRequest(kind: "ptyPoll")
                req.ptySessionId = sid
                req.waitMillis = 120
                let response = try client.send(req, timeoutSec: 3)
                let out = response.outputHex.flatMap { Self.hexToData($0) } ?? Data()
                let text = String(decoding: out, as: UTF8.self)
                DispatchQueue.main.async {
                    if !text.isEmpty { self.output += Self.sanitize(text) }
                    if response.running == false {
                        self.running = false
                        self.output += "\n[pty exited code=\(response.exitCode ?? 0)]"
                        self.timer?.invalidate()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.running = false
                    self.error = "poll: \(error.localizedDescription)"
                    self.timer?.invalidate()
                }
            }
        }
    }

    static func hexToData(_ hex: String) -> Data {
        var bytes = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let pair = hex[i..<hex.index(i, offsetBy: 2)]
            if let b = UInt8(pair, radix: 16) { bytes.append(b) }
            i = hex.index(i, offsetBy: 2)
        }
        return bytes
    }

    /// 终端为简单 scrolldown：去除 ANSI 代码云格（本阶段无 VT100 解释）；
    static func sanitize(_ raw: String) -> String {
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\u{1B}" {
                // CSI：跳 到 final byte [@-~]
                var j = raw.index(after: i)
                while j < raw.endIndex, raw[j] < "@" || raw[j] > "~" { j = raw.index(after: j) }
                if j < raw.endIndex { j = raw.index(after: j) }
                i = j
            } else if c == "\r" {
                i = raw.index(after: i)
            } else { out.append(c); i = raw.index(after: i) }
        }
        return out
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
            }
            if let err = model.error { Text(err).foregroundColor(.red).font(.caption) }
        }
        .padding()
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }
}
