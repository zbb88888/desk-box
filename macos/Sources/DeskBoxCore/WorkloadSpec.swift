import Foundation

/// 资源提示（架构 §5.2：白名单式，且只是提示；强制由宿主/平台执行）。
public struct ResourceHints: Sendable, Codable, Equatable {
    public var cpuCount: Int?
    public var memoryMiB: Int?
    public var diskMiB: Int?
    public var pids: Int?

    public init(cpuCount: Int? = nil, memoryMiB: Int? = nil, diskMiB: Int? = nil, pids: Int? = nil) {
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.diskMiB = diskMiB
        self.pids = pids
    }
}

public struct ServicePort: Sendable, Codable, Equatable {
    public enum Transport: String, Sendable, Codable {
        case tcp
        case udp
    }

    public let port: UInt16
    public let transport: Transport

    public init(port: UInt16, transport: Transport) {
        self.port = port
        self.transport = transport
    }
}

/// 受控 volume 引用：只允许映射到 Host 管理的 workspace/volume 描述，
/// 不接受任意 bind mount（架构 §5.2 拒绝项）。
public struct VolumeBinding: Sendable, Codable, Equatable {
    public let name: String
    public let readOnly: Bool

    public init(name: String, readOnly: Bool) {
        self.name = name
        self.readOnly = readOnly
    }
}

/// 白名单 WorkloadSpec：Guest 执行的唯一输入契约（双层模型 §6.3）。
/// 镜像 metadata 是输入，不是权限来源（架构 §6.5）。
public struct WorkloadSpec: Sendable, Codable, Equatable {
    public var entrypoint: [String]
    public var args: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var declaredPorts: [ServicePort]
    public var uid: UInt32
    public var gid: UInt32
    public var volumes: [VolumeBinding]
    public var resources: ResourceHints

    public init(
        entrypoint: [String],
        args: [String],
        environment: [String: String],
        workingDirectory: String,
        declaredPorts: [ServicePort],
        uid: UInt32,
        gid: UInt32,
        volumes: [VolumeBinding],
        resources: ResourceHints
    ) {
        self.entrypoint = entrypoint
        self.args = args
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.declaredPorts = declaredPorts
        self.uid = uid
        self.gid = gid
        self.volumes = volumes
        self.resources = resources
    }
}

/// OCI image config 的安全相关子集（opencontainers/image-spec）。
/// 注意 OCI image config 本身不含 privileged/namespace/device/capability
/// 字段——那些属于 runtime 层输入或 Docker 兼容 API，必须在更上层按
/// 白名单拒绝（架构 §5.2 评审修正）。此模型刻意不存在这些字段。
public struct OCIImageConfig: Sendable, Codable, Equatable {
    public var user: String?
    public var env: [String]?
    public var entrypoint: [String]?
    public var cmd: [String]?
    public var workingDir: String?
    public var volumes: Set<String>?
    public var exposedPorts: Set<String>?

    public init(
        user: String? = nil,
        env: [String]? = nil,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        workingDir: String? = nil,
        volumes: Set<String>? = nil,
        exposedPorts: Set<String>? = nil
    ) {
        self.user = user
        self.env = env
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.workingDir = workingDir
        self.volumes = volumes
        self.exposedPorts = exposedPorts
    }
}

/// 编译策略：由 Host Controller 下发，不接受镜像覆盖。
public struct CompilerPolicy: Sendable, Codable, Equatable {
    /// 允许透传的环境变量名白名单。
    public var allowedEnvNames: Set<String>
    /// 即使出现在白名单也拒绝的前缀（动态链接器劫持类）。
    public var deniedEnvPrefixes: [String]
    /// 是否允许保留 guest root；默认拒绝（架构 §6.7、双层模型 §6.2）。
    public var allowGuestRoot: Bool
    public var nonRootUID: UInt32
    public var nonRootGID: UInt32
    /// 受控 volume 映射：镜像请求的挂载路径 -> 受控绑定。
    public var allowedVolumes: [String: VolumeBinding]
    /// 资源上限；超出部分收紧并记录决策（不叫拒绝，只是提示）。
    public var caps: ResourceHints

    public init(
        allowedEnvNames: Set<String> = ["PATH", "HOME", "LANG", "TERM"],
        deniedEnvPrefixes: [String] = ["LD_", "DYLD_"],
        allowGuestRoot: Bool = false,
        nonRootUID: UInt32 = 65_534,
        nonRootGID: UInt32 = 65_534,
        allowedVolumes: [String: VolumeBinding] = [:],
        caps: ResourceHints = ResourceHints(cpuCount: 8, memoryMiB: 8192, diskMiB: 40_960, pids: 4096)
    ) {
        self.allowedEnvNames = allowedEnvNames
        self.deniedEnvPrefixes = deniedEnvPrefixes
        self.allowGuestRoot = allowGuestRoot
        self.nonRootUID = nonRootUID
        self.nonRootGID = nonRootGID
        self.allowedVolumes = allowedVolumes
        self.caps = caps
    }
}

public struct CompiledDecision: Sendable, Codable, Equatable {
    public let field: String
    public let decision: Decision

    public init(field: String, decision: Decision) {
        self.field = field
        self.decision = decision
    }
}

public struct SpecCompileResult: Sendable, Equatable {
    public let spec: WorkloadSpec
    /// 编译过程中的全部收紧决策，进入审计（矩阵 INV-06 拒绝原因审计）。
    public let decisions: [CompiledDecision]
    /// 非 nil 表示整体拒绝；spec 无效。
    public let rejection: Decision?

    public var rejected: Bool { rejection != nil }
}

public enum WorkloadSpecCompiler {
    public static func compile(image: OCIImageConfig, policy: CompilerPolicy) -> SpecCompileResult {
        var decisions: [CompiledDecision] = []

        // 1. UID/GID：request 只是提示；默认重写为固定非 root。
        var uid = policy.nonRootUID
        var gid = policy.nonRootGID
        if let user = image.user, !user.isEmpty {
            switch parseUser(user) {
            case .root:
                if policy.allowGuestRoot {
                    uid = 0
                    gid = 0
                    decisions.append(CompiledDecision(
                        field: "user",
                        decision: .allow(reason: .policyAllowed, message: "策略显式允许 guest root")
                    ))
                } else {
                    let rejection = Decision.deny(.specUserRootDenied, "镜像要求 root；默认重写为非 root，root 必需镜像按策略拒绝")
                    return SpecCompileResult(spec: .empty, decisions: decisions, rejection: rejection)
                }
            case .unixUser(let parsedUID, let parsedGID):
                uid = parsedUID
                gid = parsedGID ?? policy.nonRootGID
            case .invalid:
                let rejection = Decision.error(.specUserInvalid, "user 字段无法安全解析：仅接受数值 uid[:gid]；名称解析不在首版")
                return SpecCompileResult(spec: .empty, decisions: decisions, rejection: rejection)
            }
        } else {
            decisions.append(CompiledDecision(field: "user", decision: .allow(reason: .policyAllowed, message: "未声明 user，重写为非 root \(uid)")))
        }

        // 2. entrypoint/cmd
        let entrypoint = image.entrypoint ?? []
        let args = image.cmd ?? []

        // 3. 环境变量：白名单 + 危险前缀
        var environment: [String: String] = [:]
        for entry in image.env ?? [] {
            guard let eq = entry.firstIndex(of: "=") else {
                decisions.append(CompiledDecision(field: "env", decision: .deny(.specEnvDropped, "无值变量 \(entry) 依赖宿主解析，丢弃")))
                continue
            }
            let name = String(entry[..<eq])
            let value = String(entry[entry.index(after: eq)...])
            guard policy.allowedEnvNames.contains(name) else {
                decisions.append(CompiledDecision(field: "env", decision: .deny(.specEnvDropped, "\(name) 不在白名单，丢弃")))
                continue
            }
            if policy.deniedEnvPrefixes.contains(where: { name.hasPrefix($0) }) {
                decisions.append(CompiledDecision(field: "env", decision: .deny(.specEnvDropped, "\(name) 命中危险前缀，丢弃")))
                continue
            }
            environment[name] = value
        }

        // 4. 工作目录
        let workingDir = (image.workingDir?.isEmpty == false) ? image.workingDir! : "/"
        guard workingDir.hasPrefix("/"), !workingDir.contains("..") else {
            let rejection = Decision.error(.specWorkdirInvalid, "workingDir 必须是绝对路径且不含 ..：\(workingDir)")
            return SpecCompileResult(spec: .empty, decisions: decisions, rejection: rejection)
        }

        // 5. Volumes：默认忽略，仅保留受控映射
        var volumes: [VolumeBinding] = []
        for mount in (image.volumes ?? []).sorted() {
            if let binding = policy.allowedVolumes[mount] {
                volumes.append(binding)
            } else {
                decisions.append(CompiledDecision(field: "volumes", decision: .deny(.specVolumeDropped, "\(mount) 未映射到受控 volume，忽略")))
            }
        }

        // 6. 声明式服务端口
        var ports: [ServicePort] = []
        for raw in (image.exposedPorts ?? []).sorted() {
            guard let parsed = parsePort(raw) else {
                let rejection = Decision.error(.specPortInvalid, "无法解析 exposedPort：\(raw)")
                return SpecCompileResult(spec: .empty, decisions: decisions, rejection: rejection)
            }
            ports.append(parsed)
        }

        // 7. 资源提示按上限收紧
        let hints = ResourceHints()
        let resources = clamp(hints, to: policy.caps, decisions: &decisions)

        let spec = WorkloadSpec(
            entrypoint: entrypoint,
            args: args,
            environment: environment,
            workingDirectory: workingDir,
            declaredPorts: ports,
            uid: uid,
            gid: gid,
            volumes: volumes,
            resources: resources
        )
        return SpecCompileResult(spec: spec, decisions: decisions, rejection: nil)
    }

    private enum ParsedUser {
        case root
        case unixUser(uid: UInt32, gid: UInt32?)
        case invalid
    }

    private static func parseUser(_ raw: String) -> ParsedUser {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "root" || trimmed == "0" || trimmed == "0:0" { return .root }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return .invalid }
        guard let uid = UInt32(parts[0]) else { return .invalid }
        if uid == 0 { return .root }
        var gid: UInt32?
        if parts.count == 2, !parts[1].isEmpty {
            guard let parsedGID = UInt32(parts[1]) else { return .invalid }
            gid = parsedGID
        }
        return .unixUser(uid: uid, gid: gid)
    }

    private static func parsePort(_ raw: String) -> ServicePort? {
        let parts = raw.split(separator: "/")
        guard let port = UInt16(parts[0]), port > 0 else { return nil }
        guard parts.count <= 2 else { return nil }
        let transport: ServicePort.Transport
        if parts.count == 2 {
            guard let parsed = ServicePort.Transport(rawValue: parts[1].lowercased()) else { return nil }
            transport = parsed
        } else {
            transport = .tcp
        }
        return ServicePort(port: port, transport: transport)
    }

    private static func clamp(_ hints: ResourceHints, to caps: ResourceHints, decisions: inout [CompiledDecision]) -> ResourceHints {
        func clampValue(_ value: Int?, _ cap: Int?, _ name: String) -> Int? {
            guard let value, let cap, value > cap else { return value ?? cap }
            decisions.append(CompiledDecision(field: "resources", decision: .deny(.specResourceClamped, "\(name) \(value) 超过上限 \(cap)，已收紧")))
            return cap
        }
        return ResourceHints(
            cpuCount: clampValue(hints.cpuCount, caps.cpuCount, "cpuCount"),
            memoryMiB: clampValue(hints.memoryMiB, caps.memoryMiB, "memoryMiB"),
            diskMiB: clampValue(hints.diskMiB, caps.diskMiB, "diskMiB"),
            pids: clampValue(hints.pids, caps.pids, "pids")
        )
    }
}

extension WorkloadSpec {
    static let empty = WorkloadSpec(
        entrypoint: [], args: [], environment: [:], workingDirectory: "/",
        declaredPorts: [], uid: 0, gid: 0, volumes: [], resources: ResourceHints()
    )
}
