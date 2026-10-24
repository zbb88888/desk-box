import Foundation
import CryptoKit

/// Hex encoding/decoding used by PTY event payloads (M1-4).
enum HexCoder {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let byteString = hex[index..<hex.index(index, offsetBy: 2)]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = hex.index(index, offsetBy: 2)
        }
        return data
    }
}

/// 跨 @Sendable 边界搬运 VZ 对象引用。
/// 安全性前提：所有 VZ 对象仅在 adapter 的串行队列上访问
/// （VZVirtualMachine 创建时绑定该队列）。不得用它绕过该纪律。
struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

public enum AssetDigest {
    public static func sha256Hex(of url: URL) throws -> String {
        try DigestVerifier.sha256Hex(of: url)
    }
}

enum DigestVerifier {
    /// 流式 sha256；大 root disk 不整读入内存。
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
