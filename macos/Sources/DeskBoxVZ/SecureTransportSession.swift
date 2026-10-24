import Foundation
import Security
import DeskBoxCore

/// TLS session over an existing VZ virtio-socket file descriptor.
///
/// IMPORTANT (M1-2 decision): Security.framework's legacy SecureTransport
/// (`SSLCreateContext`) does NOT support TLS 1.3 on modern macOS —
/// `SSLSetProtocolVersionMin(.tlsProtocol13)` is rejected at runtime. It is
/// kept here as a compile/feature-gated probe for development only; the actual
/// M1-2 host implementation must use Network.framework (NWListener/NWConnection
/// on a local Unix-domain bridge) or an embedded TLS library. See
/// `docs/design/m1-tls-channel-upgrade.md` §3.1/§6.
///
/// Boundary notes (docs/design/m1-tls-channel-upgrade.md §3.1):
/// - TLS 1.3-only; min/max are pinned and renegotiation is not negotiated;
/// - handshake has a bounded deadline; any failure fails closed;
/// - after handshake the caller can read/write TLS records via `read`/`write`;
/// - the peer certificate fingerprint (SHA-256 of DER) is captured to derive
///   the session binding; ephemeral per-boot certs mean PKI is not involved.
final class SecureTransportSession: @unchecked Sendable {
    enum Role {
        case hostClient  /// Host initiates TLS client handshake on the vsock.
        case guestServer /// Reserved for symmetric configs in tests.
    }

    private var context: SSLContext?
    private let queue: DispatchQueue
    private let fileDescriptor: Int32
    private let queueKey = DispatchSpecificKey<UInt8>()
    private(set) var peerFingerprintHex: String?
    private(set) var localFingerprintHex: String?
    private(set) var sessionBinding: SessionBinding?

    init(
        fileDescriptor: Int32,
        queue: DispatchQueue,
        localIdentity: SecIdentity? = nil
    ) {
        self.fileDescriptor = fileDescriptor
        self.queue = queue
        self.queue.setSpecific(key: queueKey, value: 1)
        if let localIdentity {
            localFingerprintHex = Self.fingerprint(of: localIdentity)
        }
    }

    /// Perform the TLS handshake on the owning queue. Any failure throws and
    /// the caller must close the connection (fail-closed).
    func performHandshake(as role: Role, peerContext: BootContext, deadline: Date) throws {
        guard let ssl = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw SandboxFailure(.bootstrapTLSRequired, "TLS context creation failed")
        }
        self.context = ssl

        var status = noErr
        // Force TLS 1.3 only; anything else is rejected at the protocol level.
        status = SSLSetProtocolVersionMin(ssl, .tlsProtocol13)
        guard status == noErr else { throw SandboxFailure(.bootstrapTLSRequired, "TLS 1.3 minimum not applicable: \(status)") }
        status = SSLSetProtocolVersionMax(ssl, .tlsProtocol13)
        guard status == noErr else { throw SandboxFailure(.bootstrapTLSRequired, "TLS 1.3 maximum not applicable: \(status)") }

        let boxed = Unmanaged.passUnretained(IOContext(fd: fileDescriptor)).toOpaque()
        status = SSLSetConnection(ssl, boxed)
        guard status == noErr else { throw SandboxFailure(.bootstrapTLSRequired, "TLS connection setup failed: \(status)") }
        status = SSLSetIOFuncs(ssl, Self.sslReadCallback, Self.sslWriteCallback)
        guard status == noErr else { throw SandboxFailure(.bootstrapTLSRequired, "TLS io callback setup failed: \(status)") }

        // Server-side: the guest will always speak first after handoff;
        // host initiates as TLS client over the accepted VSOCK connection.
        status = SSLHandshake(ssl)
        while status == errSSLWouldBlock {
            if Date() >= deadline {
                throw SandboxFailure(.bootstrapTLSRequired, "TLS handshake timeout")
            }
            Thread.sleep(forTimeInterval: 0.01)
            status = SSLHandshake(ssl)
        }
        guard status == noErr else {
            throw SandboxFailure(.bootstrapTLSRequired, "TLS handshake failed: \(status)")
        }

        if let peer = try Self.copyPeerCertificateChain(ssl) {
            peerFingerprintHex = Self.sha256Hex(of: peer)
        }
        let hostFp = localFingerprintHex ?? ""
        let guestFp = peerFingerprintHex ?? ""
        sessionBinding = SessionBinding(
            hostFingerprintHex: hostFp,
            guestFingerprintHex: guestFp,
            sessionID: SessionBinding.deriveSessionID(
                hostFingerprintHex: hostFp,
                guestFingerprintHex: guestFp,
                context: peerContext
            )
        )
    }

    /// Read a single TLS record into a bounded buffer. Returns nil on EOF.
    func read(maxBytes: Int = 64 * 1024) throws -> Data? {
        guard let ssl = context else { throw SandboxFailure(.bootstrapTLSRequired, "read before handshake") }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var processed = 0
        let status = SSLRead(ssl, &buffer, maxBytes, &processed)
        switch status {
        case noErr:
            return processed == 0 ? nil : Data(buffer[0..<processed])
        case errSSLClosedGraceful, errSSLClosedAbort:
            return nil
        case errSSLWouldBlock:
            return Data()
        default:
            throw SandboxFailure(.bootstrapTLSRequired, "TLS read failed: \(status)")
        }
    }

    func write(_ data: Data) throws {
        guard let ssl = context else { throw SandboxFailure(.bootstrapTLSRequired, "write before handshake") }
        var offset = 0
        while offset < data.count {
            var processed = 0
            let status = data.withUnsafeBytes { raw in
                SSLWrite(ssl, raw.baseAddress!.advanced(by: offset), data.count - offset, &processed)
            }
            if status == errSSLWouldBlock {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            guard status == noErr else {
                throw SandboxFailure(.bootstrapTLSRequired, "TLS write failed: \(status)")
            }
            offset += processed
        }
    }

    func close() {
        if let ssl = context {
            SSLClose(ssl)
            self.context = nil
        }
    }

    private final class IOContext {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
    }

    // I/O callbacks: delegate to the raw socket fd in blocking mode.
    private static let sslReadCallback: SSLReadFunc = { connection, data, dataLength in
        let context = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
        let n = Darwin.read(context.fd, data, dataLength.pointee)
        if n < 0 {
            let err = errno
            dataLength.pointee = 0
            return err == EAGAIN ? errSSLWouldBlock : errSSLInternal
        }
        dataLength.pointee = n
        return noErr
    }

    private static let sslWriteCallback: SSLWriteFunc = { connection, data, dataLength in
        let context = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
        let n = Darwin.write(context.fd, data, dataLength.pointee)
        if n < 0 {
            let err = errno
            dataLength.pointee = 0
            return err == EAGAIN ? errSSLWouldBlock : errSSLInternal
        }
        dataLength.pointee = n
        return noErr
    }

    static func fingerprint(of identity: SecIdentity) -> String? {
        var reference: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &reference) == errSecSuccess,
              let cert = reference else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        return sha256Hex(of: der)
    }

    static func sha256Hex(of data: Data) -> String {
        ControlSessionHash.sha256Hex(of: data)
    }

    private static func copyPeerCertificateChain(_ ssl: SSLContext) throws -> Data? {
        var trust: SecTrust?
        guard SSLCopyPeerTrust(ssl, &trust) == noErr, let trust else { return nil }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let first = chain.first else { return nil }
        return SecCertificateCopyData(first) as Data
    }
}

/// Development-only identity loader: looks up the identity that
/// `scripts/gen-dev-tls.sh` imported into the login keychain by label. Per-boot
/// ephemeral generation (M1-2b) will replace this asset entirely.
struct DevelopmentTLSAssets {
    static let label = "deskbox-dev-tls"

    static func loadIdentity() throws -> SecIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let identity = item as! SecIdentity? else {
            throw SandboxFailure(
                .bootstrapTLSRequired,
                "dev TLS identity \(label) not found in login keychain (status=\(status)); run scripts/gen-dev-tls.sh first"
            )
        }
        return identity
    }
}
