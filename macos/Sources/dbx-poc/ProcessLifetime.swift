import Foundation
import Darwin

/// Keeps the foreground POC alive while making normal termination observable.
/// SIGINT/SIGTERM are converted into a continuation result, so the caller can
/// execute the same stop/destroy cleanup path as stdin EOF.
final class ProcessLifetime: @unchecked Sendable {
    enum ExitReason: Sendable {
        case stdinEOF
        case signal(Int32)
    }

    private let queue = DispatchQueue(label: "com.deskbox.poc-lifetime")
    private var signalSources: [DispatchSourceSignal] = []
    private var stdinSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<ExitReason, Never>?
    private var finished = false

    func wait() async -> ExitReason {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.finished else {
                    continuation.resume(returning: .stdinEOF)
                    return
                }
                self.continuation = continuation
                self.installSources()
            }
        }
    }

    private func installSources() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.finish(.signal(number))
            }
            source.resume()
            signalSources.append(source)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: FileHandle.standardInput.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let count = read(FileHandle.standardInput.fileDescriptor, &byte, 1)
            if count == 0 { self.finish(.stdinEOF) }
            else if count < 0 { self.finish(.stdinEOF) }
        }
        source.setCancelHandler {}
        stdinSource = source
        source.resume()
    }

    private func finish(_ reason: ExitReason) {
        guard !finished else { return }
        finished = true
        stdinSource?.cancel()
        stdinSource = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: reason)
    }

    deinit {
        signalSources.forEach { $0.cancel() }
        stdinSource?.cancel()
    }
}
