import DeskBoxCore
import Foundation

/// M22：更新检查（docs/design/m22-distribution-notarization.md §5）。
///
/// 语义纪律：
/// - 只读 channel 的公开内容，全部 fail-closed；
/// - 只做「告知」，不下载、不替换（自动替换属 M22c）；
/// - 版本回滚（远端 < 本地）一律拒绝，这是 INV-10「不复活旧版本」在分发面的延伸。
public enum UpdateDecision: String, Sendable, Equatable, Codable {
    case available = "available"
    case upToDate = "up-to-date"
    case rollback = "rollback"
}

public enum UpdateCheckError: Error, Equatable, CustomStringConvertible {
    case versionUnparseable(String)
    case rollbackRefused(current: String, remote: String)
    case noUsableReleaseKey(count: Int)
    case channel(ReleaseChannelError)

    public var description: String {
        switch self {
        case .versionUnparseable(let v): return "update-version-unparseable: \(v)"
        case .rollbackRefused(let c, let r): return "update-rollback-refused: remote=\(r) current=\(c)"
        case .noUsableReleaseKey(let n): return "update-no-usable-release-key: keys=\(n)"
        case .channel(let e): return "update-channel-invalid: \(e)"
        }
    }
}

/// 语义化版本（只支持 `MAJOR.MINOR.PATCH[-pre][+build]`，与 release tag `v` 前缀配合）。
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init(parsing raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // 丢掉 build metadata（`+...`），它不参与比较。
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }
        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            prerelease = String(text[text.index(after: dash)...])
                .split(separator: ".").map(String.init)
            text = String(text[text.startIndex..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            throw UpdateCheckError.versionUnparseable(raw)
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    /// semver 2.0 precedence：数字段按数值比较；预发布 < 正式；预发布按段比较。
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 无预发布 = 正式版 > 任何预发布
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            let ln = Int(l), rn = Int(r)
            switch (ln, rn) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true    // 数字标识符 < 字母标识符
            case (.none, .some): return false
            case (.none, .none): return l < r
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct UpdateCheckResult: Sendable, Equatable, Codable {
    public let schema: String
    public let decision: UpdateDecision
    public let currentVersion: String
    public let remoteVersion: String?
    public let releaseTag: String?
    public let manifestDigest: String?
    public let assetVersion: Int?
    public let reason: String?

    public static let schemaValue = "deskbox-update-check/v1"

    public var isRefusal: Bool { decision == .rollback }
}

public enum UpdateChecker {
    /// 检查 channel 相对当前版本的更新可用性。任何不完整/不可信的 channel 都抛错。
    ///
    /// - Parameters:
    ///   - channelURL: channel.json 路径（本地文件；远程抓取由调用方完成并落盘后传入）
    ///   - currentVersion: 当前 app 版本（semver，允许带 `v` 前缀）
    ///   - now: 注入时钟，便于测试 key 有效期
    public static func check(channelURL: URL,
                             currentVersion: String,
                             now: Date = Date()) throws -> UpdateCheckResult {
        let channel: ReleaseChannelManifest
        do {
            channel = try ReleaseChannelVerifier.verify(channelURL: channelURL).channel
        } catch let error as ReleaseChannelError {
            throw UpdateCheckError.channel(error)
        }
        // release key 必须至少有一把当前可用（active + 在有效期内）。
        let usableKeys = channel.keys.filter { ReleaseKeysManifest.isUsable($0, at: now) }
        guard !usableKeys.isEmpty else {
            throw UpdateCheckError.noUsableReleaseKey(count: channel.keys.count)
        }
        let current = try SemanticVersion(parsing: currentVersion)
        let remote = try SemanticVersion(parsing: channel.releaseTag)

        if remote < current {
            throw UpdateCheckError.rollbackRefused(current: current.description,
                                                   remote: remote.description)
        }
        let decision: UpdateDecision = remote == current ? .upToDate : .available
        return UpdateCheckResult(
            schema: UpdateCheckResult.schemaValue,
            decision: decision,
            currentVersion: current.description,
            remoteVersion: remote.description,
            releaseTag: channel.releaseTag,
            manifestDigest: channel.manifest.manifestDigest,
            assetVersion: channel.manifest.assetVersion,
            reason: nil
        )
    }

    /// 失败时也给出结构化结果（便于 CLI --json 与 GUI 展示统一）。
    public static func refusal(currentVersion: String, error: Error) -> UpdateCheckResult {
        let reason: String
        if let e = error as? UpdateCheckError { reason = e.description }
        else if let e = error as? ReleaseChannelError { reason = "update-channel-invalid: \(e)" }
        else { reason = "update-check-failed: \(error)" }
        return UpdateCheckResult(
            schema: UpdateCheckResult.schemaValue,
            decision: .rollback,
            currentVersion: currentVersion,
            remoteVersion: nil,
            releaseTag: nil,
            manifestDigest: nil,
            assetVersion: nil,
            reason: reason
        )
    }
}
