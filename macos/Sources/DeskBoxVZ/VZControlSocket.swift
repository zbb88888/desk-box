import Foundation
@preconcurrency import Virtualization
import DeskBoxCore

/// A bounded host-side VZ virtio-socket session. The file descriptor is owned
/// by VZVirtioSocketConnection; this object keeps the connection alive and
/// closes it on session teardown.
final class VZControlSocket: NSObject, @unchecked Sendable {
    private let connection: VZVirtioSocketConnection
    private let queue: DispatchQueue
    private let onFrames: @Sendable ([ControlFrame]) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var source: DispatchSourceRead?
    private var decoder = ControlFrameDecoder()
    private var sequence = ControlSequenceGuard()
    private var writeLock = NSLock()
    private var closed = false

    init(
        connection: VZVirtioSocketConnection,
        queue: DispatchQueue,
        onFrames: @escaping @Sendable ([ControlFrame]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onFrames = onFrames
        self.onFailure = onFailure
        super.init()
        startReading()
    }

    func send(_ frame: ControlFrame) throws {
        FileHandle.standardError.write(Data("dbx-vz: socket send kind=\(frame.kind) seq=\(frame.sequence)\n".utf8))
        try? FileHandle.standardError.synchronize()
        try send(bytes: frame.encoded())
    }

    func send(bytes data: Data) throws {
        guard !closed else {
            throw SandboxFailure(.bootstrapProofMismatch, "VZ control socket closed before write")
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                write(connection.fileDescriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written <= 0 {
                throw SandboxFailure(.bootstrapProofMismatch, "VZ control socket 写入失败")
            }
            offset += written
        }
    }

    func close() {
        writeLock.lock()
        guard !closed else {
            writeLock.unlock()
            return
        }
        closed = true
        source?.cancel()
        source = nil
        connection.close()
        writeLock.unlock()
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: connection.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [connection] in
            connection.close()
        }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(connection.fileDescriptor, &bytes, bytes.count)
        FileHandle.standardError.write(Data("dbx-vz: socket read count=\(count)\n".utf8))
        try? FileHandle.standardError.synchronize()
        guard count > 0 else {
            if count == 0 { onFailure("guest control socket closed") }
            else {
                let message = "guest control socket read failed: errno=\(errno)"
                FileHandle.standardError.write(Data("dbx-vz: \(message)\n".utf8))
                try? FileHandle.standardError.synchronize()
                onFailure(message)
            }
            close()
            return
        }
        do {
            let preview = String(decoding: Data(bytes[0..<min(count, 16)]), as: UTF8.self)
            FileHandle.standardError.write(Data("dbx-vz: received preview=\(preview)\n".utf8))
            try? FileHandle.standardError.synchronize()
            let frames = try decoder.append(Data(bytes[0..<count]))
            if frames.isEmpty {
                FileHandle.standardError.write(Data("dbx-vz: decoder yielded no frames\n".utf8))
                try? FileHandle.standardError.synchronize()
            }
            for frame in frames { try sequence.accept(frame) }
            if !frames.isEmpty { onFrames(frames) }
        } catch {
            FileHandle.standardError.write(Data("dbx-vz: socket read error=\(error.localizedDescription)\n".utf8))
            try? FileHandle.standardError.synchronize()
            if let failure = error as? SandboxFailure {
                FileHandle.standardError.write(Data("dbx-vz: sandbox failure reason=\(failure.reason)\n".utf8))
                try? FileHandle.standardError.synchronize()
            }
            onFailure(error.localizedDescription)
            close()
        }
    }
}

/// VZ listener delegate. It accepts only the configured control port and keeps
/// no unauthenticated connection as a product session; TLS/bootstrap is still
/// required before a frame can change lifecycle state.
final class VZControlSocketDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: @Sendable (VZVirtioSocketConnection) -> Void
    let onReject: @Sendable (String) -> Void

    init(
        onConnection: @escaping @Sendable (VZVirtioSocketConnection) -> Void,
        onReject: @escaping @Sendable (String) -> Void
    ) {
        self.onConnection = onConnection
        self.onReject = onReject
        super.init()
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let fileDescriptor = connection.fileDescriptor
        FileHandle.standardError.write(Data("dbx-vz: incoming virtio-socket connection fd=\(fileDescriptor)\n".utf8))
        try? FileHandle.standardError.synchronize()
        guard fileDescriptor >= 0 else {
            onReject("VZ control connection has invalid file descriptor")
            return false
        }
        onConnection(connection)
        return true
    }
}
