import Foundation
@preconcurrency import Virtualization
import DeskBoxCore

/// A bounded host-side VZ virtio-socket session. The file descriptor is owned
/// by VZVirtioSocketConnection; this object keeps the connection alive and
/// closes it on session teardown.
///
/// After the HelloAck exchange the channel may be upgraded to record
/// protection (M1-2): frames then travel as AEAD-sealed records with an
/// explicit 4-byte length prefix, while the underlying ControlFrame framing
/// (magic/version/sequence) still applies inside the plaintext. Malformed or
/// replayed frames fail closed in both modes.
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

    /// Record framing buffer (used after transport upgrade).
    private var recordBuffer = Data()
    private var secureSession: SecureRecordSession?

    var fileDescriptor: Int32 { connection.fileDescriptor }

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

    /// Switch to the encrypted record transport. Requires guest-side framing to
    /// match ([u32be length][sealed frame]); future frames continue to pass the
    /// ControlFrame magic/sequence checks after decryption.
    func upgradeTransport(to session: SecureRecordSession) {
        secureSession = session
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
        var outbound = data
        if let session = secureSession {
            let sealed = try session.encrypt(frameData: data)
            outbound = Self.encodeRecordPayload(sealed)
        }
        var offset = 0
        while offset < outbound.count {
            let written = outbound.withUnsafeBytes { raw in
                write(connection.fileDescriptor, raw.baseAddress!.advanced(by: offset), outbound.count - offset)
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
        secureSession = nil
        recordBuffer.removeAll()
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
        if secureSession != nil {
            handleEncryptedChunk(Data(bytes[0..<count]))
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

    private static func encodeRecordPayload(_ sealed: Data) -> Data {
        var payload = Data(capacity: 4 + sealed.count)
        var value = UInt32(sealed.count).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &value) { Array($0) })
        payload.append(sealed)
        return payload
    }

    private static func decodeRecordLength(from data: Data) -> (length: Int, offset: Int)? {
        guard data.count >= 4 else { return nil }
        let bytes = Array(data.prefix(4))
        let length = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        return (length, 4)
    }

    private func handleEncryptedChunk(_ chunk: Data) {
        recordBuffer.append(chunk)
        guard let session = secureSession else { return }
        // Bounded record framing: u32be length, then sealed bytes.
        while recordBuffer.count >= 4,
              let (recordLength, offset) = Self.decodeRecordLength(from: recordBuffer) {
            guard recordLength >= 16, // AEAD tag
                  recordLength <= 1 << 20 else {
                onFailure("TLS record length out of bounds: \(recordLength)")
                close()
                return
            }
            if recordBuffer.count < offset + recordLength { break }
            let record = Data(recordBuffer[offset..<(offset + recordLength)])
            recordBuffer = Data(recordBuffer.dropFirst(offset + recordLength))
            do {
                let plaintext = try session.decrypt(record: record)
                let frames = try decoder.append(plaintext)
                for frame in frames { try sequence.accept(frame) }
                for frame in frames { onFrames([frame]) }
            } catch {
                onFailure("record protection failed: \(error.localizedDescription)")
                close()
                return
            }
        }
        if recordBuffer.count > ControlFrame.headerSize + ControlFrame.defaultMaximumPayload + 256 {
            onFailure("record buffer overflow")
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
