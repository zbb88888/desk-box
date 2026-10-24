import DeskBoxCore
import Foundation

/// Guest SBOM（docs/design/m3-supply-chain.md；INV-09）。
/// 用于记录 guest 资产内容 digest 与供给 manifestation；本地 verify-sbom 复验。
public struct GuestSbom: Sendable, Equatable, Codable {
    public let schema: String
    public let builtAtUtc: String
    public let assetVersion: Int
    public let inputs: [Entry]
    public let outputs: [Entry]

    public init(schema: String, builtAtUtc: String, assetVersion: Int, inputs: [Entry], outputs: [Entry]) {
        self.schema = schema
        self.builtAtUtc = builtAtUtc
        self.assetVersion = assetVersion
        self.inputs = inputs
        self.outputs = outputs
    }

    public struct Entry: Sendable, Equatable, Codable {
        public let name: String
        public let url: String?
        /// 仓库内相对路径（如 macos/scripts/...）。
        public let path: String?
        /// 相对于 sbomDir 的下载/输出文件名（如 vmlinuz-virt）。
        public let file: String?
        public let sha256: String?

        public init(name: String, url: String? = nil, path: String? = nil, file: String? = nil, sha256: String? = nil) {
            self.name = name
            self.url = url
            self.path = path
            self.file = file
            self.sha256 = sha256
        }
    }
}

public enum GuestSbomError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case malformed(String)
    case missingDigest(String)
    case digestMismatch(String, computed: String, declared: String)

    public var description: String {
        switch self {
        case .unreadable(let p): return "SBOM 不可读: \(p)"
        case .malformed(let r): return "SBOM 格式非法: \(r)"
        case .missingDigest(let n): return "SBOM entry 缺少 digest: \(n)"
        case .digestMismatch(let n, let c, let d): return "SBOM digest 不匹配 \(n)：computed=\(c) declared=\(d)"
        }
    }
}

public enum GuestSbomVerifier {
    /// 验证 sbom 中每个带 path 的输入与输出文件的 sha256 是否与实际一致（fail-closed）。
    public static func verify(sbomURL: URL) throws -> GuestSbom {
        guard FileManager.default.isReadableFile(atPath: sbomURL.path) else {
            throw GuestSbomError.unreadable(sbomURL.path)
        }
        let sbom: GuestSbom
        do {
            sbom = try JSONDecoder().decode(GuestSbom.self, from: Data(contentsOf: sbomURL))
        } catch {
            throw GuestSbomError.malformed(error.localizedDescription)
        }
        guard sbom.schema == "deskbox-guest-sbom/v1" else {
            throw GuestSbomError.malformed("unexpected schema \(sbom.schema)")
        }
        let sbomDir = sbomURL.deletingLastPathComponent()
        for entry in sbom.inputs + sbom.outputs {
            // 无 sha 记录的条目是 provenance-only（远程下载种源来源），或无人拒绝收入面；
            // fail-closed 的 digest 验证只作用于 costs本地可重新计算的目面。
            guard let declared = entry.sha256 else { continue }
            guard declared.count == 64 else { throw GuestSbomError.missingDigest(entry.name) }
            let resolved: URL
            if let repoRel = entry.path {
                resolved = sbomDir.deletingLastPathComponent().appendingPathComponent(repoRel)
            } else if let name = entry.file {
                resolved = sbomDir.appendingPathComponent(name)
            } else {
                resolved = sbomDir.appendingPathComponent(entry.name)
            }
            let actual = try DigestVerifier.sha256Hex(of: resolved.standardizedFileURL)
            guard actual == declared else {
                throw GuestSbomError.digestMismatch(entry.name, computed: actual, declared: declared)
            }
        }
        return sbom
    }
}
