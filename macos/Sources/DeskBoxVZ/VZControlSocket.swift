import Foundation
@preconcurrency import Virtualization
import DeskBoxCore

/// A bounded host-side VZ virtio-socket session. The file descriptor is owned
/// by VZVirtioSocketConnection; this object keeps the connection alive and
/// closes it on session teardown.
///
/// Frame validation stays strict (magic/version/length/sequence). Malformed or
/// replayed frames fail closed and the connection is dropped; failures are
/// surfaced through `onFailure` for audit instead of debug printing.
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

    /// Synchronous read used by the runtime after sending a request frame.
    /// It shares the same bounded decoder and sequence guard as the async
    /// reader; replayed or malformed frames still fail closed.
    func pollRead() throws -> [ControlFrame] {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let capacity = bytes.capacity
        let count = bytes.withUnsafeMutableBytes { raw in
            read(connection.fileDescriptor, raw.baseAddress, capacity)
        }
        guard count > 0 else { return [] }
        let frames = try decoder.append(Data(bytes[0..<count]))
        for frame in frames { try sequence.accept(frame) }
        return frames
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let capacity = bytes.capacity
        // `read` needs the element storage, not the Swift array object pointer.
        // Passing `&bytes` writes past the array header and corrupts the heap.
        let count = bytes.withUnsafeMutableBytes { raw in
            read(connection.fileDescriptor, raw.baseAddress, capacity)
        }
        guard count > 0 else {
            if count == 0 { onFailure("guest control socket closed") }
            else { onFailure("guest control socket read failed: errno=\(errno)") }
            close()
            return
        }
        do {
            let frames = try decoder.append(Data(bytes[0..<count]))
            for frame in frames { try sequence.accept(frame) }
            for frame in frames { onFrames([frame]) }
        } catch {
            onFailure(error.localizedDescription)
            close()
        }
    }
}

/// VZ listener delegate. It accepts only the configured control port and keeps
/// no unauthenticated connection as a product session; bootstrap/TLS is still
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
        guard connection.fileDescriptor >= 0 else {
            onReject("VZ control connection has invalid file descriptor")
            return false
        }
        onConnection(connection)
        return true
    }
}
