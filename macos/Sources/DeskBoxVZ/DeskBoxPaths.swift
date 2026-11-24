import Foundation

/// M25：DeskBox 宿主侧状态根目录（domains.json / snapshot.key / cows / dbxd.sock /
/// scheduler-decisions.jsonl）的唯一解析点。
///
/// 默认 `~/Library/Application Support/DeskBox`。设置环境变量 `DBX_SUPPORT_ROOT`
/// 可整体重定向——用途是测试隔离（e2e 不再读写用户真实状态，也不与用户的 daemon 抢
/// cow-root）以及多实例并存。
///
/// fail-closed：变量一旦设置就必须合法，非法值**拒绝运行**而不是静默回落到默认目录
/// （否则「以为跑在隔离目录、其实在动真实状态」）。它不是提权面：能设置 daemon 环境
/// 变量的主体本来就能以同一用户身份直接读写这些文件。
public enum DeskBoxPaths {
    public static let supportRootEnvKey = "DBX_SUPPORT_ROOT"

    public enum PathError: Error, CustomStringConvertible, Equatable {
        case notAbsolute(String)
        case containsParentTraversal(String)
        case notADirectory(String)

        public var description: String {
            switch self {
            case .notAbsolute(let v): return "\(supportRootEnvKey) 必须是绝对路径：\(v)"
            case .containsParentTraversal(let v): return "\(supportRootEnvKey) 不得包含 ..：\(v)"
            case .notADirectory(let v): return "\(supportRootEnvKey) 已存在但不是目录：\(v)"
            }
        }
    }

    /// 纯解析（可单测）：未设置/空串 → 默认目录；否则校验后原样采用。
    public static func resolveSupportRoot(environment: [String: String]) throws -> URL {
        guard let raw = environment[supportRootEnvKey], !raw.isEmpty else {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeskBox", isDirectory: true)
        }
        guard raw.hasPrefix("/") else { throw PathError.notAbsolute(raw) }
        guard !raw.split(separator: "/").contains("..") else { throw PathError.containsParentTraversal(raw) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: raw, isDirectory: &isDir), !isDir.boolValue {
            throw PathError.notADirectory(raw)
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    /// 进程级解析结果。非法覆盖值直接终止进程（exit 2），与 domains.json 非法时的处理一致。
    public static let supportRoot: URL = {
        do {
            return try resolveSupportRoot(environment: ProcessInfo.processInfo.environment)
        } catch {
            fputs("deskbox: FATAL \(error)\n", stderr)
            exit(2)
        }
    }()

    public static var cowRoot: URL { supportRoot.appendingPathComponent("cows", isDirectory: true) }
    public static var snapshotKeyURL: URL { supportRoot.appendingPathComponent("snapshot.key") }
    public static var daemonSocketURL: URL { supportRoot.appendingPathComponent("dbxd.sock") }

    /// 覆盖模式下目录由我们创建时收紧到 0700（里面有 snapshot.key 与凭据表）。
    public static func ensureSupportRootExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: supportRoot.path) else { return }
        try? fm.createDirectory(at: supportRoot, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }
}
