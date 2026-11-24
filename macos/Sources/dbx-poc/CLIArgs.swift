import Foundation

/// M27：daemon 生命周期子命令的声明式参数解析（纯函数，可单元测试）。
///
/// 原先各子命令手写 `try? optionString(...)`，问题是**出错即回落默认值**（fail-open）：
/// - `--daemon-sock` 缺值 → 静默连到默认 socket（脚本里 `$SOCK` 为空时，`shutdown` 会关掉
///   用户真实的 daemon）；
/// - `--memory-mib 4G` 之类非法值被忽略；未知选项被忽略（`--froce` 变成非 force）；
/// - `exec` 在 `--` 之后仍然解析选项，guest 命令行里的 `--timeout` / `--env` 等被吃掉；
/// - 选项写在位置参数之前会被当成位置参数（`exec --timeout 5 <id>` → id = "--timeout"）。
///
/// 规则（全部 fail-closed）：
/// - `--` 之前：已知带值选项必须有非空值，且值不能是另一个已知选项；`--opt=value` 等价；
///   非 repeatable 选项重复即报错；未知的 `-x` / `--x` 报错；其余是位置参数（位置无关）；
/// - `--` 之后：原样透传，一个字节都不解析（仅 `allowsPassthrough` 的命令接受 `--`）；
/// - 位置参数个数必须正好等于声明数。
struct CLISpec {
    let command: String
    let usage: String
    var positionals: [String] = []
    /// 可省略的位置参数（排在必填的之后）。
    var optionalPositionals: [String] = []
    var valueOptions: Set<String> = []
    var repeatableOptions: Set<String> = []
    var flags: Set<String> = []
    var allowsPassthrough = false

    var allOptions: Set<String> { valueOptions.union(repeatableOptions).union(flags) }
}

struct CLIParsed {
    let spec: CLISpec
    fileprivate(set) var positionals: [String] = []
    fileprivate(set) var values: [String: [String]] = [:]
    fileprivate(set) var flags: Set<String> = []
    /// `--` 之后的原样参数；命令行里没有 `--` 时为 nil。
    fileprivate(set) var passthrough: [String]? = nil

    func positional(_ index: Int) -> String { positionals[index] }
    /// 可省略的位置参数；没给返回 nil。
    func optionalPositional(_ index: Int) -> String? { index < positionals.count ? positionals[index] : nil }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func string(_ name: String) -> String? { values[name]?.last }
    func strings(_ name: String) -> [String] { values[name] ?? [] }

    /// 严格整数：必须整个 token 是十进制整数且落在范围内。
    func int(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let raw = string(name) else { return nil }
        guard let value = Int(raw), range.contains(value), raw.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw CLIError.usage("\(spec.command): invalid value for \(name): '\(raw)' (expected integer \(range.lowerBound)…\(range.upperBound))")
        }
        return value
    }
}

enum CLIArgs {
    static func parse(_ args: [String], spec: CLISpec) throws -> CLIParsed {
        var parsed = CLIParsed(spec: spec)
        let known = spec.allOptions
        var i = 0
        while i < args.count {
            let token = args[i]
            if token == "--" {
                guard spec.allowsPassthrough else {
                    throw CLIError.usage("\(spec.command): unexpected '--' | usage: \(spec.usage)")
                }
                parsed.passthrough = Array(args[(i + 1)...])
                break
            }
            // --opt=value
            var name = token
            var inlineValue: String? = nil
            if token.hasPrefix("--"), let eq = token.firstIndex(of: "=") {
                name = String(token[..<eq])
                inlineValue = String(token[token.index(after: eq)...])
            }
            if spec.flags.contains(name) {
                guard inlineValue == nil else {
                    throw CLIError.usage("\(spec.command): option \(name) does not take a value")
                }
                parsed.flags.insert(name)
                i += 1
                continue
            }
            if spec.valueOptions.contains(name) || spec.repeatableOptions.contains(name) {
                let value: String
                if let inlineValue {
                    value = inlineValue
                    i += 1
                } else {
                    guard i + 1 < args.count else {
                        throw CLIError.usage("\(spec.command): missing value for \(name)")
                    }
                    value = args[i + 1]
                    // `--daemon-sock --force`：下一个 token 是选项而不是值。
                    guard value != "--", !known.contains(value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? value) else {
                        throw CLIError.usage("\(spec.command): missing value for \(name) (got option '\(value)')")
                    }
                    i += 2
                }
                // 空值几乎总是脚本里未设置的变量；回落默认值会操作到错误的对象。
                guard !value.isEmpty else {
                    throw CLIError.usage("\(spec.command): empty value for \(name)")
                }
                if !spec.repeatableOptions.contains(name), parsed.values[name] != nil {
                    throw CLIError.usage("\(spec.command): option \(name) given more than once")
                }
                parsed.values[name, default: []].append(value)
                continue
            }
            if token.hasPrefix("-") && token.count > 1 {
                throw CLIError.usage("\(spec.command): unknown option '\(name)' | usage: \(spec.usage)")
            }
            parsed.positionals.append(token)
            i += 1
        }
        let allPositionals = spec.positionals + spec.optionalPositionals
        if parsed.positionals.count < spec.positionals.count {
            let missing = spec.positionals[parsed.positionals.count]
            throw CLIError.usage("\(spec.command): \(missing) required | usage: \(spec.usage)")
        }
        if parsed.positionals.count > allPositionals.count {
            let extra = parsed.positionals[allPositionals.count]
            throw CLIError.usage("\(spec.command): unexpected argument '\(extra)' | usage: \(spec.usage)")
        }
        // 位置参数为空串同样是未设置变量的征兆。
        for (index, value) in parsed.positionals.enumerated() where value.isEmpty {
            throw CLIError.usage("\(spec.command): empty \(allPositionals[index])")
        }
        return parsed
    }

    /// `KEY=VALUE`；KEY 非空且不含 `=`。非法即报错（原先静默丢弃）。
    static func parseEnvPairs(_ pairs: [String], command: String) throws -> [String: String]? {
        guard !pairs.isEmpty else { return nil }
        var out: [String: String] = [:]
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else {
                throw CLIError.usage("\(command): invalid --env '\(pair)' (expected KEY=VALUE)")
            }
            out[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return out
    }
}

/// daemon 生命周期子命令的规格表（单一事实来源；usage 文本由此派生）。
enum DaemonCLISpecs {
    private static let sock = "--daemon-sock"
    private static let domain = "--domain"

    static let run = CLISpec(
        command: "run",
        usage: "dbx-poc run <manifest.json> [--workspace dir] [--oci-bundle b] [--daemon-sock p] [--allow-plaintext] [--allow-unsigned-manifest] [--release-keys f] [--memory-mib N] [--cpus N] [--cow-root d] [--domain id]",
        positionals: ["manifest path"],
        valueOptions: [sock, domain, "--workspace", "--oci-bundle", "--release-keys", "--memory-mib", "--cpus", "--cow-root"],
        flags: ["--allow-plaintext", "--allow-unsigned-manifest"])

    static let ps = CLISpec(command: "ps", usage: "dbx-poc ps [--daemon-sock p]", valueOptions: [sock])

    static let exec = CLISpec(
        command: "exec",
        usage: "dbx-poc exec <sandbox-id> [--cwd d] [--timeout N] [--env K=V]... [--domain id] [--daemon-sock p] -- <argv...>",
        positionals: ["sandbox id"],
        valueOptions: [sock, domain, "--timeout", "--cwd"],
        repeatableOptions: ["--env"],
        allowsPassthrough: true)

    static let stop = single("stop")
    static let restart = single("restart")
    static let console = single("console")
    static let suspend = single("suspend")
    static let resume = single("resume")

    static let rm = CLISpec(
        command: "rm", usage: "dbx-poc rm <sandbox-id> [--force] [--domain id] [--daemon-sock p]",
        positionals: ["sandbox id"], valueOptions: [sock, domain], flags: ["--force"])

    static let stats = CLISpec(
        command: "stats", usage: "dbx-poc stats <sandbox-id> [--json] [--domain id] [--daemon-sock p]",
        positionals: ["sandbox id"], valueOptions: [sock, domain], flags: ["--json"])

    static let wsSync = CLISpec(
        command: "ws-sync",
        usage: "dbx-poc ws-sync <sandbox-id> <directory> [--allow-unsafe-resync] [--domain id] [--daemon-sock p]",
        positionals: ["sandbox id", "workspace directory"], valueOptions: [sock, domain], flags: ["--allow-unsafe-resync"])

    static let shutdown = CLISpec(command: "shutdown", usage: "dbx-poc shutdown [--daemon-sock p]", valueOptions: [sock])
    static let daemon = CLISpec(command: "daemon", usage: "dbx-poc daemon [--daemon-sock p]", valueOptions: [sock])
    static let sweep = CLISpec(command: "sweep", usage: "dbx-poc sweep [--cow-root d]", valueOptions: ["--cow-root"])

    private static func single(_ name: String) -> CLISpec {
        CLISpec(command: name, usage: "dbx-poc \(name) <sandbox-id> [--domain id] [--daemon-sock p]",
                positionals: ["sandbox id"], valueOptions: [sock, domain])
    }

    static let all: [CLISpec] = [run, ps, exec, stop, restart, console, suspend, resume, rm, stats, wsSync, shutdown, daemon, sweep]
}
