import DeskBoxCore
import Foundation

/// WorkloadSpec Compiler/Policy（docs/design/m2-2-oci-workload.md，INV-06）。
/// 解析 OCI config.json 并拒绝一切可扩权字段；输出 ResolvedWorkload 供 workspace sync + exec 执行。
public struct ResolvedWorkload: Sendable, Equatable {
    public let argv: [String]
    public let cwd: String
    public let env: [String: String]
    /// rootfs 绝对路径（「OCI root.path + bundle dir」解析后传递给 WorkspaceSyncService）
    public let rootfsURL: URL?

    public init(argv: [String], cwd: String, env: [String: String], rootfsURL: URL?) {
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.rootfsURL = rootfsURL
    }
}

public enum OciPolicyError: Error, Equatable, CustomStringConvertible {
    case emptyArgs
    case cwdNotUnderWorkspace(String)
    case envKeyInvalid(String)
    case envValueTooLong(String)
    case envPairsMalformed(String)
    case uidNotNobody(Int)
    case privilegedRequested
    case mountOutsideWorkspace(String)
    case mountSourceSuspicious(String)
    case namespaceUnsupported(String)
    case ociRootOutsideBundle(String)

    public var description: String {
        switch self {
        case .emptyArgs: return "process.args 不可为空"
        case .cwdNotUnderWorkspace(let c): return "process.cwd 必须在 /workspace 之下: \(c)"
        case .envKeyInvalid(let k): return "env key 不合规或属禁用命名空间（DBX_/PATH/HOME/USER）: \(k)"
        case .envValueTooLong(let k): return "环境值超长: \(k)"
        case .envPairsMalformed(let s): return "环境值格式非法（K=V）: \(s)"
        case .uidNotNobody(let u): return "process.user.uid 仅允许 nobody 65534；拒绝 uid=\(u)"
        case .privilegedRequested: return "linux.privileged 及任何扩权特性 fail-closed 拒绝"
        case .mountOutsideWorkspace(let d): return "mount destination 必须在 /workspace 之下: \(d)"
        case .mountSourceSuspicious(let s): return "mount source 不允许（绝对路径/dev/proc/sys）: \(s)"
        case .namespaceUnsupported(let t): return "namespace path 形式在此阶段不支持: \(t)"
        case .ociRootOutsideBundle(let p): return "oci.root.path 越出 bundle 根: \(p)"
        }
    }
}

public enum OciPolicyValidator {
    public static let workspacePrefix = "/workspace"

    /// M19 corpus 发现的路径穿越：`/workspace/../etc` 这类字符串前缀检查会通过，
    /// 但实际解析到 workspace 之外。凡出现 `..` 组件一律拒绝（fail-closed）。
    static func containsParentTraversal(_ path: String) -> Bool {
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { return true }
        }
        return false
    }

    static func isUnderWorkspace(_ path: String) -> Bool {
        guard !containsParentTraversal(path) else { return false }
        return path == workspacePrefix || path.hasPrefix(workspacePrefix + "/")
    }

    public static func validate(spec: OciRuntimeSpec, bundleDir: URL) throws -> ResolvedWorkload {
        guard !spec.process.args.isEmpty else { throw OciPolicyError.emptyArgs }
        guard isUnderWorkspace(spec.process.cwd) else {
            throw OciPolicyError.cwdNotUnderWorkspace(spec.process.cwd)
        }
        if let user = spec.process.user, user.uid != 65534 { throw OciPolicyError.uidNotNobody(user.uid) }
        if spec.linux?.privileged == true { throw OciPolicyError.privilegedRequested }
        if let namespaces = spec.linux?.namespaces {
            for ns in namespaces where ns.path != nil {
                throw OciPolicyError.namespaceUnsupported(ns.type)
            }
        }
        if let mounts = spec.mounts {
            for mount in mounts {
                guard isUnderWorkspace(mount.destination) else {
                    throw OciPolicyError.mountOutsideWorkspace(mount.destination)
                }
                if let source = mount.source,
                   (source.contains("/dev") || source.contains("/proc") || source.contains("/sys") || source.hasPrefix("/")) {
                    throw OciPolicyError.mountSourceSuspicious(source)
                }
            }
        }
        var env: [String: String] = [:]
        if let envList = spec.process.env {
            guard envList.count <= 8 else { throw OciPolicyError.envPairsMalformed("count>8") }
            for item in envList {
                guard let eq = item.firstIndex(of: "=") else { throw OciPolicyError.envPairsMalformed(item) }
                let key = String(item[..<eq])
                let value = String(item[item.index(after: eq)...])
                guard envKeyValid(key) else { throw OciPolicyError.envKeyInvalid(key) }
                guard value.count <= 160 else { throw OciPolicyError.envValueTooLong(key) }
                env[key] = value
            }
        }
        var rootfsURL: URL? = nil
        if let root = spec.root {
            // 绝对路径与含 `..` 的 root.path 一律拒绝（bundle 内相对路径才允许）。
            guard !root.path.hasPrefix("/"), !containsParentTraversal(root.path) else {
                throw OciPolicyError.ociRootOutsideBundle(root.path)
            }
            let resolved = bundleDir.appendingPathComponent(root.path).standardizedFileURL
            let rootPath = resolved.path
            // root.path 必须在 bundleDir 下（../ 拒绝）。
            guard rootPath.hasPrefix(bundleDir.standardizedFileURL.path + "/") else {
                throw OciPolicyError.ociRootOutsideBundle(root.path)
            }
            rootfsURL = resolved
        }
        return ResolvedWorkload(argv: spec.process.args, cwd: spec.process.cwd, env: env, rootfsURL: rootfsURL)
    }

    private static func envKeyValid(_ key: String) -> Bool {
        guard !key.isEmpty, !key.allSatisfy(\.isNumber), key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else { return false }
        if key.hasPrefix("DBX_") { return false }
        if ["PATH", "HOME", "USER"].contains(key) { return false }
        return true
    }
}
