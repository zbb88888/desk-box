import Foundation
import DeskBoxCore

/// VZ 不验证 Linux boot asset 签名；宿主在启动前验证 manifest 与每个文件 digest。
/// 这不是远程证明：它只保证启动输入符合宿主已接受的清单。
public enum GuestAssetValidator {
    public struct ValidatedManifest: Sendable, Equatable {
        public let manifestDigest: String
        public let assetVersion: Int
        public let totalBytes: UInt64

        public init(manifestDigest: String, assetVersion: Int, totalBytes: UInt64) {
            self.manifestDigest = manifestDigest
            self.assetVersion = assetVersion
            self.totalBytes = totalBytes
        }
    }

    public static func validate(
        _ manifest: GuestAssetManifest,
        minimumAssetVersion: Int = 1
    ) throws -> ValidatedManifest {
        guard manifest.guestAssetVersion >= minimumAssetVersion else {
            throw SandboxFailure(.platformAssetDigestMismatch, "guest asset 版本低于安全最低版本")
        }
        guard !manifest.kernelCommandLine.contains("init=/bin/sh") else {
            throw SandboxFailure(.platformAssetDigestMismatch, "禁止使用直接 shell 作为 guest init")
        }
        let required = [manifest.kernelURL] + (manifest.initrdURL.map { [$0] } ?? []) + [manifest.rootDiskURL]
        var totalBytes: UInt64 = 0
        for url in required {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw SandboxFailure(.platformAssetDigestMismatch, "boot asset 不可读：\(url.path)")
            }
            guard let expected = manifest.fileDigests[url.standardizedFileURL.path]?.lowercased(),
                  expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit }) else {
                throw SandboxFailure(.platformAssetDigestMismatch, "缺少或非法 digest：\(url.path)")
            }
            let actual = try DigestVerifier.sha256Hex(of: url)
            guard actual == expected else {
                throw SandboxFailure(.platformAssetDigestMismatch, "asset digest 不匹配：\(url.path)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            totalBytes += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        return ValidatedManifest(manifestDigest: manifest.manifestDigest, assetVersion: manifest.guestAssetVersion, totalBytes: totalBytes)
    }
}
