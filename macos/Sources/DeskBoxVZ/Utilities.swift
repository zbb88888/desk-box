import Foundation
import CryptoKit

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
