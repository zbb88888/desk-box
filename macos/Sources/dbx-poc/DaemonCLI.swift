import Foundation

/// M27：把「命令行 → DaemonRequest」做成纯函数，CLI 入口只负责发送与打印。
/// 这样参数语义（哪些选项进了请求、`--` 之后是否原样透传）可以直接单测。
struct DaemonInvocation {
    var request: DaemonRequest
    /// nil = 默认 socket（`DeskBoxPaths.daemonSocketURL`）。只有命令行**没有**给 `--daemon-sock`
    /// 时才为 nil；给了但缺值/空值在解析阶段就已报错，不会回落到默认 socket。
    var sock: String?
    var json = false
}

enum DaemonCLI {
    static func run(_ args: [String]) throws -> DaemonInvocation {
        let p = try CLIArgs.parse(args, spec: DaemonCLISpecs.run)
        var request = DaemonRequest(kind: "run")
        request.manifestPath = p.positional(0)
        request.workspaceDir = p.string("--workspace")
        request.ociBundlePath = p.string("--oci-bundle")
        request.allowPlaintext = p.flag("--allow-plaintext")
        request.allowUnsignedManifest = p.flag("--allow-unsigned-manifest")
        request.releaseKeysPath = p.string("--release-keys")
        request.memoryMiB = try p.int("--memory-mib", in: 1...1_048_576)
        request.cpus = try p.int("--cpus", in: 1...256)
        request.cowRoot = p.string("--cow-root")
        request.domain = p.string("--domain")
        return DaemonInvocation(request: request, sock: p.string("--daemon-sock"))
    }

    static func exec(_ args: [String]) throws -> DaemonInvocation {
        let spec = DaemonCLISpecs.exec
        let p = try CLIArgs.parse(args, spec: spec)
        guard let argv = p.passthrough, !argv.isEmpty else {
            throw CLIError.usage("exec requires argv via '-- ...' | usage: \(spec.usage)")
        }
        var request = DaemonRequest(kind: "exec")
        request.sandboxId = p.positional(0)
        request.argv = argv
        request.cwd = p.string("--cwd")
        request.timeoutSeconds = try p.int("--timeout", in: 1...86_400)
        request.env = try CLIArgs.parseEnvPairs(p.strings("--env"), command: "exec")
        request.domain = p.string("--domain")
        return DaemonInvocation(request: request, sock: p.string("--daemon-sock"))
    }

    static func rm(_ args: [String]) throws -> DaemonInvocation {
        let p = try CLIArgs.parse(args, spec: DaemonCLISpecs.rm)
        var request = DaemonRequest(kind: "rm")
        request.sandboxId = p.positional(0)
        request.force = p.flag("--force")
        request.domain = p.string("--domain")
        return DaemonInvocation(request: request, sock: p.string("--daemon-sock"))
    }

    static func stats(_ args: [String]) throws -> DaemonInvocation {
        let p = try CLIArgs.parse(args, spec: DaemonCLISpecs.stats)
        var request = DaemonRequest(kind: "stats")
        request.sandboxId = p.positional(0)
        request.domain = p.string("--domain")
        return DaemonInvocation(request: request, sock: p.string("--daemon-sock"), json: p.flag("--json"))
    }

    /// M37：把宿主目录同步进沙箱的 /workspace。
    static func wsSync(_ args: [String]) throws -> DaemonInvocation {
        let p = try CLIArgs.parse(args, spec: DaemonCLISpecs.wsSync)
        var request = DaemonRequest(kind: "wsSync")
        request.sandboxId = p.positional(0)
        request.workspaceDir = URL(fileURLWithPath: p.positional(1)).standardizedFileURL.path
        request.domain = p.string("--domain")
        // 只有显式给了才发送：缺省即「不接受风险」。
        if p.flag("--allow-unsafe-resync") { request.allowUnsafeResync = true }
        return DaemonInvocation(request: request, sock: p.string("--daemon-sock"))
    }

    static func console(_ args: [String]) throws -> DaemonInvocation {
        var inv = try single(args, spec: DaemonCLISpecs.console, kind: "consoleLog")
        inv.request.waitMillis = 16384
        return inv
    }

    /// 单 id 端点：stop / restart / suspend / resume（以及 console 的基础部分）。
    static func single(_ args: [String], spec: CLISpec, kind: String) throws -> DaemonInvocation {
        let p = try CLIArgs.parse(args, spec: spec)
        var request = DaemonRequest(kind: kind)
        request.sandboxId = p.positional(0)
        request.domain = p.string("--domain")
        return DaemonInvocation(request: request, sock: p.string("--daemon-sock"))
    }

    /// 无参端点：ps / shutdown。
    static func bare(_ args: [String], spec: CLISpec, kind: String) throws -> DaemonInvocation {
        let p = try CLIArgs.parse(args, spec: spec)
        return DaemonInvocation(request: DaemonRequest(kind: kind), sock: p.string("--daemon-sock"))
    }

    /// `dbx-poc daemon` 的 socket 路径。
    static func daemonSocket(_ args: [String]) throws -> String? {
        try CLIArgs.parse(args, spec: DaemonCLISpecs.daemon).string("--daemon-sock")
    }

    /// `dbx-poc sweep` 的 cow-root。
    static func sweepCowRoot(_ args: [String]) throws -> URL? {
        try CLIArgs.parse(args, spec: DaemonCLISpecs.sweep).string("--cow-root")
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}
