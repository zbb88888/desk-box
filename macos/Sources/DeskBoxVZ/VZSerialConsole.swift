import Foundation
@preconcurrency import Virtualization

/// Host-side serial pipes for the Linux guest console.
/// The console is diagnostic only: output is bounded by the pipe/consumer and
/// never becomes a readiness or attestation signal.
final class VZSerialConsole: @unchecked Sendable {
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let onOutput: @Sendable (Data) -> Void

    /// Host writes commands to the guest serial input.
    var hostWriteHandle: FileHandle { inputPipe.fileHandleForWriting }
    /// Host reads bytes emitted by the guest serial output.
    var hostReadHandle: FileHandle { outputPipe.fileHandleForReading }

    /// `fileHandleForReading` is read by the guest; `fileHandleForWriting`
    /// is written by the guest. Do not reverse these pipe ends.
    var attachment: VZFileHandleSerialPortAttachment {
        VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
    }

    init(onOutput: @escaping @Sendable (Data) -> Void) {
        self.inputPipe = Pipe()
        self.outputPipe = Pipe()
        self.onOutput = onOutput
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.onOutput(data)
        }
    }

    func close() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForReading.close()
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }
}
