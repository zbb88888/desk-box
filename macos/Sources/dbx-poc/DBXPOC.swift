import Foundation
import DeskBoxCore
import DeskBoxVZ

@main
struct DBXPOC {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "capcheck", nil:
                _ = try CLIArgs.parse(Array(args.dropFirst()), spec: ReleaseCLISpecs.capcheck)
                let report = VZCapabilityProbe.probe()
                print(String(decoding: try JSONEncoder.pretty.encode(report), as: UTF8.self))
            case "verify-sbom":
                let first = try CLIArgs.parse(Array(args.dropFirst()), spec: ReleaseCLISpecs.verifySbom).positional(0)
                let sbom = try GuestSbomVerifier.verify(sbomURL: URL(fileURLWithPath: first))
                print("sbom verified assetVersion=\(sbom.assetVersion) inputs=\(sbom.inputs.count) outputs=\(sbom.outputs.count)")
            case "validate-assets":
                let p = try CLIArgs.parse(Array(args.dropFirst()), spec: ReleaseCLISpecs.validateAssets)
                let first = p.positional(0)
                let manifest = try loadManifest(at: URL(fileURLWithPath: first))
                if let chainPath = p.string("--release-keys") {
                    let chainData = try Data(contentsOf: URL(fileURLWithPath: chainPath))
                    let raw = try JSONDecoder().decode(ReleaseKeyFile.self, from: chainData)
                    let chain = ReleaseKeysManifest(schema: raw.schema, generatedAtUtc: raw.generatedAtUtc, keys: raw.keys)
                    do {
                        try ManifestSigner.verify(manifest: manifest.asManifest,
                                                 chain: chain,
                                                 allowUnsignedManifest: p.flag("--allow-unsigned-manifest"))
                    } catch let error as ManifestSignerError {
                        throw SandboxFailure(.platformAssetDigestMismatch, error.description)
                    }
                    print("validated manifest \(manifest.manifestDigest) against release-keys （\(chain.keys.count) keys）")
                } else {
                    let result = try GuestAssetValidator.validate(manifest.asManifest,
                                                                  allowUnsignedManifest: p.flag("--allow-unsigned-manifest"))
                    print("validated manifest \(result.manifestDigest)")
                }
            case "make-manifest":
                try makeManifest(args: Array(args.dropFirst()))
            case "gen-guest-sign-key":
                try genGuestSignKey(args: Array(args.dropFirst()))
            case "sign-manifest":
                try signManifest(args: Array(args.dropFirst()))
            case "gen-release-key":
                try genReleaseKey(args: Array(args.dropFirst()))
            case "rotate-release-key":
                try rotateReleaseKey(args: Array(args.dropFirst()))
            case "revoke-release-key":
                try revokeReleaseKey(args: Array(args.dropFirst()))
            case "publish":
                try publishReleaseChannel(args: Array(args.dropFirst()))
            case "verify-channel":
                try verifyReleaseChannel(args: Array(args.dropFirst()))
            case "version":
                _ = try CLIArgs.parse(Array(args.dropFirst()), spec: ReleaseCLISpecs.version)
                try printVersion()
            case "domains":
                try listDomains(args: Array(args.dropFirst()))
            case "check-update":
                try checkUpdate(args: Array(args.dropFirst()))
            case "launch":
                try await launch(args: Array(args.dropFirst()))
            case "sweep":
                try sweep(args: Array(args.dropFirst()))
            case "daemon":
                // M27：缺值/空值/未知选项一律报错，不回落到默认 socket。
                let sockPath = try DaemonCLI.daemonSocket(Array(args.dropFirst())) ?? SandboxDaemon.defaultSockPath()
                try SandboxDaemon(sockPath: sockPath).serve()
            case "run":   try daemonRunCli(args: Array(args.dropFirst()))
            case "ps":    try daemonPsCli(args: Array(args.dropFirst()))
            case "exec":  try daemonExecCli(args: Array(args.dropFirst()))
            case "exec-cancel":
                let inv = try DaemonCLI.single(Array(args.dropFirst()), spec: DaemonCLISpecs.execCancel, kind: "execCancel")
                let response = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
                print(response.stdout ?? "exec cancelled")
            case "stop":  try daemonStopCli(args: Array(args.dropFirst()))
            case "rm":    try daemonRmCli(args: Array(args.dropFirst()))
            case "shutdown": try daemonShutdownCli(args: Array(args.dropFirst()))
            case "restart": try daemonRestartCli(args: Array(args.dropFirst()))
            case "console": try daemonConsoleCli(args: Array(args.dropFirst()))
            case "stats": try daemonStatsCli(args: Array(args.dropFirst()))
            case "ws-sync":
                let inv = try DaemonCLI.wsSync(Array(args.dropFirst()))
                let response = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
                print(response.stdout ?? "ws-sync ok")
            case "suspend": try daemonSimpleCli(args: Array(args.dropFirst()), kind: "suspend", spec: DaemonCLISpecs.suspend)
            case "resume": try daemonSimpleCli(args: Array(args.dropFirst()), kind: "resume", spec: DaemonCLISpecs.resume)
            case "help", "-h", "--help":
                printUsage()
            default:
                throw CLIError.usage("unknown command")
            }
        } catch CLIError.exit(let code) {
            // M39：`exec` 把 guest 命令的退出码原样传给调用方（此前一律 exit 2 并打印「exit code N」，
            // 与 CLI 自身的用法错误无法区分，脚本也拿不到真实的退出码）。
            Foundation.exit(ExecExitStatus.processStatus(forGuestExitCode: code))
        } catch {
            fputs("dbx-poc: \(error)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func genGuestSignKey(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.genGuestSignKey)
        guard let outputPath = p.string("--output-key") else {
            throw CLIError.usage("dbx-poc gen-guest-sign-key --output-key <path>")
        }
        let pair = ManifestSigner.generateKeypairHex()
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        // M34：私钥 0600 原子写入（此前是默认权限，umask 022 下同机任何用户可读）。
        try PrivateKeyFile.write("private:\(pair.privateHex)\n", to: output)
        print("public:\(pair.publicHex)")
        print("wrote key material \(output.path)")
    }

    private static func signManifest(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.signManifest)
        guard let inputPath = p.string("--manifest"),
              let keyPath = p.string("--key"),
              let outputPath = p.string("--output")
        else {
            throw CLIError.usage("dbx-poc sign-manifest --manifest <in> --key <path> --output <out> [--asset-version N]")
        }
        var manifest = try loadSignedManifestPreservingURLs(at: URL(fileURLWithPath: inputPath))
        if let version = try p.int("--asset-version", in: ReleaseCLISpecs.versionRange) {
            manifest = ManifestFile(
                kernelURL: manifest.kernelURL, initrdURL: manifest.initrdURL, rootDiskURL: manifest.rootDiskURL,
                kernelCommandLine: manifest.kernelCommandLine,
                guestAssetVersion: version,
                manifestDigest: manifest.manifestDigest,
                fileDigests: manifest.fileDigests,
                signature: manifest.signature,
                sbomDigest: manifest.sbomDigest
            )
        }
        let raw = try String(contentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8)
        guard let privateHex = raw.components(separatedBy: "private:").last?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CLIError.usage("key file missing private material")
        }
        let signature = try ManifestSigner.sign(payload: manifest.asManifest.signingPayload, privateKeyHex: privateHex)
        let signed = ManifestFile(
            kernelURL: manifest.kernelURL, initrdURL: manifest.initrdURL, rootDiskURL: manifest.rootDiskURL,
            kernelCommandLine: manifest.kernelCommandLine,
            guestAssetVersion: manifest.guestAssetVersion,
            manifestDigest: manifest.manifestDigest,
            fileDigests: manifest.fileDigests,
            signature: signature,
            sbomDigest: manifest.sbomDigest
        )
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        try JSONEncoder.pretty.encode(signed).write(to: output, options: .atomic)
        print("signed manifest \(output.path) keyID=\(signature.keyID)")
    }

    private struct ReleaseKeyFile: Codable {
        var schema: String
        var generatedAtUtc: String
        var keys: [ReleaseKeysManifest.Key]
    }

    private static func loadReleaseKeys(at path: String) throws -> ReleaseKeysManifest {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode(ReleaseKeyFile.self, from: data)
        return ReleaseKeysManifest(schema: raw.schema, generatedAtUtc: raw.generatedAtUtc, keys: raw.keys)
    }

    private static func writeReleaseKeys(_ manifest: ReleaseKeysManifest, to path: String) throws {
        let raw = ReleaseKeyFile(schema: manifest.schema, generatedAtUtc: manifest.generatedAtUtc, keys: manifest.keys)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(raw).write(to: url, options: .atomic)
    }

    private static func genReleaseKey(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.genReleaseKey)
        guard let outputPath = p.string("--output-key") else {
            throw CLIError.usage("dbx-poc gen-release-key --output-key <path>")
        }
        let pair = ManifestSigner.generateKeypairHex()
        let keyID = String(pair.publicHex.prefix(16))
        let starter = ReleaseKeysManifest(
            schema: ReleaseKeysManifest.schemaValue,
            generatedAtUtc: ISO8601DateFormatter().string(from: Date()),
            keys: [ReleaseKeysManifest.Key(
                keyID: keyID,
                publicHex: pair.publicHex,
                status: .active,
                notBefore: ISO8601DateFormatter().string(from: Date()),
                notAfter: nil,
                note: "generated locally (dev chain)"
            )]
        )
        try PrivateKeyFile.write("private:\(pair.privateHex)\n", to: URL(fileURLWithPath: outputPath).standardizedFileURL)
        let starterURL = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
            .appendingPathComponent("release-keys.json")
        if !FileManager.default.fileExists(atPath: starterURL.path) {
            try writeReleaseKeys(starter, to: starterURL.path)
            print("public:\(pair.publicHex)")
            print("keyID=\(keyID) wrote starter release-keys.json at \(starterURL.path)")
        } else {
            print("public:\(pair.publicHex)")
            print("keyID=\(keyID) (release-keys.json exists; update manually via rotate-release-key/revoke-release-key)")
        }
    }

    private static func rotateReleaseKey(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.rotateReleaseKey)
        guard let base = p.string("--base"),
              let newKeyPath = p.string("--new-key")
        else { throw CLIError.usage("dbx-poc rotate-release-key --base <release-keys.json> --new-key <path> [--output <out>]") }
        let outPath = p.string("--output") ?? base
        var manifest = try loadReleaseKeys(at: base)
        let raw = try String(contentsOf: URL(fileURLWithPath: newKeyPath), encoding: .utf8)
        guard let privateHex = raw.components(separatedBy: "private:").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pubHex = try? ManifestSigner.publicKeyHex(fromPrivateHex: privateHex) else {
            throw CLIError.usage("new key file missing private material")
        }
        let keyID = String(pubHex.prefix(16))
        // 所有 active 降级为 retired；新 key 以 active 双话领开始。
        for idx in manifest.keys.indices where manifest.keys[idx].status == .active {
            manifest.keys[idx] = ReleaseKeysManifest.Key(
                keyID: manifest.keys[idx].keyID,
                publicHex: manifest.keys[idx].publicHex,
                status: .retired,
                notBefore: manifest.keys[idx].notBefore,
                notAfter: manifest.keys[idx].notAfter,
                note: manifest.keys[idx].note
            )
        }
        manifest.keys.append(ReleaseKeysManifest.Key(
            keyID: keyID,
            publicHex: pubHex,
            status: .active,
            notBefore: ISO8601DateFormatter().string(from: Date()),
            notAfter: nil,
            note: "rotated in"
        ))
        try writeReleaseKeys(manifest, to: outPath)
        print("rotated release keys: new keyID=\(keyID); total=\(manifest.keys.count)")
    }

    private static func revokeReleaseKey(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.revokeReleaseKey)
        guard let base = p.string("--base"),
              let keyID = p.string("--key-id")
        else { throw CLIError.usage("dbx-poc revoke-release-key --base <release-keys.json> --key-id <id> [--output <out>]") }
        let outPath = p.string("--output") ?? base
        var manifest = try loadReleaseKeys(at: base)
        guard let idx = manifest.keys.firstIndex(where: { $0.keyID == keyID }) else {
            throw CLIError.usage("keyID not in manifest: \(keyID)")
        }
        manifest.keys[idx] = ReleaseKeysManifest.Key(
            keyID: manifest.keys[idx].keyID,
            publicHex: manifest.keys[idx].publicHex,
            status: .revoked,
            notBefore: manifest.keys[idx].notBefore,
            notAfter: manifest.keys[idx].notAfter,
            note: manifest.keys[idx].note
        )
        try writeReleaseKeys(manifest, to: outPath)
        print("revoked keyID=\(keyID)")
    }

    private static func publishReleaseChannel(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.publish)
        guard let channelDirPath = p.string("--channel") else {
            throw CLIError.usage("dbx-poc publish --channel <dir> --manifest <path> --sbom <path> --release-keys <path> [--release-tag <tag>] [--min-version-floor N]")
        }
        guard let manifestPath = p.string("--manifest"),
              let sbomPath = p.string("--sbom"),
              let releaseKeysPath = p.string("--release-keys")
        else { throw CLIError.usage("dbx-poc publish 需 manifest/sbom/release-keys") }
        /// M11：`SOURCE_DATE_EPOCH` 如来，generatedAtUtc 顺从于它（幂等发布）。
        let releaseNow: Date = {
            if let sec = ProcessInfo.processInfo.environment["SOURCE_DATE_EPOCH"],
               let epoch = TimeInterval(sec) {
                return Date(timeIntervalSince1970: epoch)
            }
            return Date()
        }()
        let releaseTag = p.string("--release-tag")
            ?? ISO8601DateFormatter().string(from: releaseNow)
        let floor = try p.int("--min-version-floor", in: ReleaseCLISpecs.versionRange) ?? 1
        let manifestRaw = try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard let sig = manifestRaw.signature else { throw CLIError.usage("publish 要求已签名 manifest") }
        let releaseKeysRaw = try Data(contentsOf: URL(fileURLWithPath: releaseKeysPath))
        let releaseKeys = try JSONDecoder().decode(ReleaseKeyFile.self, from: releaseKeysRaw)
        guard releaseKeys.keys.contains(where: { $0.keyID == sig.keyID && $0.status == .active }) else {
            throw CLIError.usage("publish 要求 signature keyID 是 active key")
        }
        if manifestRaw.guestAssetVersion < floor {
            throw CLIError.usage("publish floor 下挂 assetVersion \(manifestRaw.guestAssetVersion) < floor \(floor)")
        }
        let channelDir = URL(fileURLWithPath: channelDirPath).standardizedFileURL
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        let channelManifestURL = channelDir.appendingPathComponent("manifest.json")
        let channelSbomURL = channelDir.appendingPathComponent("sbom.json")
        try Data(contentsOf: URL(fileURLWithPath: manifestPath)).write(to: channelManifestURL, options: .atomic)
        try Data(contentsOf: URL(fileURLWithPath: sbomPath)).write(to: channelSbomURL, options: .atomic)
        /// M11：digest 覆盖 payload 而非 signature 字节（签名本身不 deterministic，证龄签证不易构）。
        let manifestFile = try loadSignedManifestPreservingURLs(at: channelManifestURL)
        let payloadDigest = try ManifestSigner.payloadDigestHex(payload: manifestFile.asManifest.signingPayload)
        let manifestDigest = payloadDigest
        let sbomDigest = try AssetDigest.sha256Hex(of: channelSbomURL)
        struct ChannelFile: Codable {
            let schema: String; let generatedAtUtc: String; let releaseTag: String
            let minGuestAssetVersionFloor: Int; let keys: [ReleaseKeysManifest.Key]
            let manifest: ReleaseChannelManifest.Manifest
        }
        let channel = ChannelFile(
            schema: ReleaseChannelManifest.schemaValue,
            generatedAtUtc: ISO8601DateFormatter().string(from: releaseNow),
            releaseTag: releaseTag,
            minGuestAssetVersionFloor: floor,
            keys: releaseKeys.keys,
            manifest: ReleaseChannelManifest.Manifest(
                files: .init(manifest: "manifest.json", sbom: "sbom.json"),
                assetVersion: manifestRaw.guestAssetVersion,
                manifestDigest: manifestDigest,
                sbomDigest: sbomDigest
            )
        )
        try JSONEncoder.pretty.encode(channel).write(to: channelDir.appendingPathComponent("channel.json"), options: .atomic)
        print("published release channel at \(channelDir.path) tag=\(releaseTag) keys=\(releaseKeys.keys.count)")
    }

    private static func verifyReleaseChannel(args: [String]) throws {
        let channelPath = try CLIArgs.parse(args, spec: ReleaseCLISpecs.verifyChannel).positional(0)
        let result = try ReleaseChannelVerifier.verify(channelURL: URL(fileURLWithPath: channelPath))
        print("verified channel tag=\(result.channel.releaseTag) assetVersion=\(result.channel.manifest.assetVersion) keys=\(result.channel.keys.count)")
    }

    private static func makeManifest(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.makeManifest)
        guard let kernelPath = p.string("--kernel"),
              let rootDiskPath = p.string("--root-disk"),
              let outputPath = p.string("--output")
        else {
            throw CLIError.usage("dbx-poc make-manifest --kernel <vmlinuz> --root-disk <disk> [--initrd <initrd>] --output <manifest.json>")
        }
        let kernel = URL(fileURLWithPath: kernelPath).standardizedFileURL
        let rootDisk = URL(fileURLWithPath: rootDiskPath).standardizedFileURL
        let initrd = p.string("--initrd").map { URL(fileURLWithPath: $0).standardizedFileURL }
        let assetVersion = try p.int("--asset-version", in: ReleaseCLISpecs.versionRange) ?? 1
        let files = [kernel] + (initrd.map { [$0] } ?? []) + [rootDisk]
        for file in files where !FileManager.default.isReadableFile(atPath: file.path) {
            throw CLIError.usage("asset is not readable: \(file.path)")
        }
        /// M11 幂等：仅 basename 为键，路径可迁移。
        var digests: [String: String] = [:]
        for file in files { digests[file.lastPathComponent] = try AssetDigest.sha256Hex(of: file) }
        /// M11：URL 与 digest 键同棄 basename，跨 build/download 目录八乘等称 byte-identical。
        func relativeURL(_ url: URL) -> URL { URL(string: url.lastPathComponent)! }
        let manifest = ManifestFile(
            kernelURL: relativeURL(kernel),
            initrdURL: initrd.map(relativeURL),
            rootDiskURL: relativeURL(rootDisk),
            kernelCommandLine: "console=hvc0 root=/dev/vda rw init=/init",
            guestAssetVersion: assetVersion,
            manifestDigest: "unsigned-local-manifest",
            fileDigests: digests,
            signature: nil,
            sbomDigest: p.string("--sbom-digest")
        )
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(manifest).write(to: output, options: .atomic)
        print("wrote unsigned manifest \(output.path) — sign with `dbx-poc sign-manifest` before launch")
    }

    private static func launch(args: [String]) async throws {
        // M34：声明式解析（未知选项 / 缺值 / 非法整数一律报错；manifest 不必是第一个参数）。
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.launch)
        let manifestPath = p.positional(0)
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        let manifest = try loadManifest(at: manifestURL)
        let cowRoot = p.string("--cow-root").map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? DeskBoxPaths.cowRoot
        let memoryMiB = try p.int("--memory-mib", in: 1...1_048_576) ?? 2048
        let cpus = try p.int("--cpus", in: 1...256) ?? 2
        guard memoryMiB > 0, cpus > 0 else {
            throw CLIError.usage("--memory-mib and --cpus must be positive")
        }

        let audit = InMemoryAuditSink()
        let diagnosticOnly = p.flag("--minimal-vz")
        // M1-2: the encrypted record channel is on by default. `--allow-plaintext`
        // is an explicit downgrade switch kept for guest-side debugging only.
        // M1-5: `--allow-unsigned-manifest` is the manifest-side twin of that flag.
        let plaintextAllowed = p.flag("--allow-plaintext")
        let unsignedAllowed = p.flag("--allow-unsigned-manifest")
        if unsignedAllowed {
            fputs("dbx-poc: warning: unsigned manifest allowed (development only)\n", stderr)
        }
        let runtime = try VZRuntime(
            cowRoot: cowRoot,
            audit: audit,
            enableConsole: !diagnosticOnly,
            enableControlSocket: !diagnosticOnly,
            securityPolicy: plaintextAllowed ? ControlSecurityPolicy() : .strict,
            allowUnsignedManifest: unsignedAllowed
        )
        runtime.brokerConfigDir = URL(fileURLWithPath: "./guest")
        if p.flag("--graphics") { runtime.enableGraphics = true }
        do {
            let sweep = try runtime.sweepOrphans()
            if !sweep.isEmpty {
                fputs("dbx-poc: swept orphaned sandboxes=\(sweep.orphanedSandboxes.count) removedClones=\(sweep.removedCloneFiles.count)\n", stderr)
                fflush(stderr)
            }
        } catch {
            fputs("dbx-poc: orphan sweep refused unsafe registry: \(error)\n", stderr)
            Foundation.exit(2)
        }
        let sandboxID = SandboxID.new()
        let workload = WorkloadSpec(
            entrypoint: ["/bin/sh"], args: [],
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/home/sandbox"],
            workingDirectory: "/", declaredPorts: [], uid: 65_534, gid: 65_534,
            volumes: [], resources: ResourceHints(cpuCount: cpus, memoryMiB: memoryMiB)
        )
        let request = SandboxCreateRequest(
            sandboxID: sandboxID, workspaceID: .new(), correlationID: UUID(),
            workloadDigest: "sha256:local-poc", workload: workload,
            guestAssets: manifest.asManifest,
            resources: ResourceHints(cpuCount: cpus, memoryMiB: memoryMiB), networking: .none
        )

        let handle = try await runtime.create(request)
        do {
            let boot = try await runtime.start(handle)
            let output = LaunchOutput(
                sandboxID: handle.sandboxID, bootID: handle.bootID,
                state: "pending-bootstrap", boot: boot,
                message: "VM 已启动；等待 guest bootstrap proof。输入 EOF 结束。"
            )
            print(String(decoding: try JSONEncoder.pretty.encode(output), as: UTF8.self))
            fflush(stdout)
            print("bootstrap=pending")
            let statusTask = Task {
                var last: BootstrapState = .notConnected
                var elapsed = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    elapsed += 500
                    if let status = try? await runtime.inspect(handle) {
                        if status.bootstrap != last {
                            last = status.bootstrap
                            print("bootstrap=\(status.bootstrap.rawValue)")
                            fflush(stdout)
                        }
                        if elapsed % 5000 == 0 && status.bootstrap == .notConnected {
                            fputs("dbx-poc: guest bootstrap not connected after \(elapsed / 1000)s; inspect serial console and guest initramfs\n", stderr)
                        }
                    }
                }
            }
            let authenticatedDeadline = Date().addingTimeInterval(15)
            while true {
                let status = try await runtime.inspect(handle)
                let booted = status.bootstrap == .authenticated || status.bootstrap == .tlsAuthenticated
                if booted && status.state == .running {
                    print("state=running")
                    fflush(stdout)
                    let commands: [[String]] = [
                        ["/bin/echo", "deskbox-mvp-first"],
                        ["/bin/echo", "deskbox-mvp-second"]
                    ]
                    // M2-3a: 凭据/网络 Broker —— 宿主拉取 allowlisted URL 并同步进 guest。
                    if let brokerURLString = p.string("--broker-preload"),
                       let brokerURL = URL(string: brokerURLString) {
                        do {
                            let policyPath = URL(fileURLWithPath: "./guest/broker-policy.json").standardizedFileURL
                            let policy = try BrokerPolicy.load(from: policyPath)
                            let credentials = CredentialBroker.load(from: URL(fileURLWithPath: "./guest/broker-credentials.local"))
                            let broker = BrokerService(policy: policy, credentials: credentials)
                            let (data, report) = try await broker.fetch(brokerURL)
                            print("broker-fetch ok status=\(report.statusCode) bytes=\(report.bytes) truncated=\(report.truncated) sha256=\(report.sha256Hex.prefix(16))…")
                            fflush(stdout)
                            // 送 bundled snapshot 一致落位。
                            let staging = FileManager.default.temporaryDirectory
                                .appendingPathComponent("deskbox-broker-\(UUID().uuidString)", isDirectory: true)
                            try FileManager.default.createDirectory(at: staging.appendingPathComponent("inbound"), withIntermediateDirectories: true)
                            let basename = brokerURL.lastPathComponent.isEmpty ? "index.html" : brokerURL.lastPathComponent
                            let fname = "\(report.sha256Hex.prefix(16))-\(basename)"
                            let target = staging.appendingPathComponent("inbound/").appendingPathComponent(fname)
                            try data.write(to: target)
                            let snapshot = try WorkspaceSyncService.buildSnapshot(root: staging)
                            let ack = try await runtime.pushWorkspace(handle, snapshot: snapshot)
                            print("broker-sync ok wsId=\(ack.wsId) files=\(snapshot.files.count) bytes=\(snapshot.totalBytes)")
                            fflush(stdout)
                            try? FileManager.default.removeItem(at: staging)
                        } catch {
                            fputs("dbx-poc: broker preload failed: \(error)\n", stderr)
                            fflush(stderr)
                        }
                    }
                    // M2-3b: guest 侧请求 broker（经由 AF_UNIX + vsock + 加密 record channel）。
                    if let guestBrokerURL = p.string("--broker-guest-url") {
                        do {
                            // guest savePath 语义：basename(url)，空路径段取 host，保 guest 端一致。
                            let parsed = URL(string: guestBrokerURL)
                            let tail = parsed?.path.split(separator: "/").last.map(String.init)
                                ?? parsed?.host
                                ?? "index.html"
                            let fname = tail.isEmpty ? "index.html" : tail
                            let execResult = try await runtime.ptyRoundTrip(
                                handle,
                                argv: ["/bin/sh", "-c",
                                       "brokerreq \(guestBrokerURL) && for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; if [ -s /workspace/inbound/\(fname) ]; then busybox sha256sum /workspace/inbound/\(fname); exit 0; fi; done; exit 1"],
                                inputHex: nil, timeoutSeconds: 25
                            )
                            print("broker-guest outbound=\(guestBrokerURL) exit=\(execResult.exitCode ?? -1) stdout=\(execResult.stdoutText.replacingOccurrences(of: "\n", with: " | "))")
                            fflush(stdout)
                        } catch {
                            fputs("dbx-poc: broker guest flow failed: \(error)\n", stderr)
                            fflush(stderr)
                        }
                    }
                    // M2-2: OCI bundle 入口：policy 审核 → 同步 rootfs → OCI 语义执行。
                    if let bundlePath = p.string("--oci-bundle") {
                        do {
                            let bundleDir = URL(fileURLWithPath: bundlePath).standardizedFileURL
                            let configURL = bundleDir.appendingPathComponent("config.json")
                            let spec = try JSONDecoder().decode(OciRuntimeSpec.self, from: Data(contentsOf: configURL))
                            let workload = try OciPolicyValidator.validate(spec: spec, bundleDir: bundleDir)
                            if let rootfs = workload.rootfsURL {
                                let snapshot = try WorkspaceSyncService.buildSnapshot(root: rootfs)
                                let ack = try await runtime.pushWorkspace(handle, snapshot: snapshot)
                                print("oci-sync ok wsId=\(ack.wsId) files=\(snapshot.files.count) bytes=\(snapshot.totalBytes)")
                                fflush(stdout)
                            }
                            let execResponse = try await runtime.execute(handle, request: ControlRequest(
                                kind: .exec,
                                argv: workload.argv,
                                env: workload.env.isEmpty ? nil : workload.env,
                                cwd: workload.cwd,
                                timeoutSeconds: 8
                            ))
                            print("oci-exec=\(execResponse.exitCode) stdout=\(execResponse.stdout.replacingOccurrences(of: "\n", with: " | "))")
                            fflush(stdout)
                        } catch {
                            fputs("dbx-poc: oci-bundle failed: \(error)\n", stderr)
                            fflush(stderr)
                        }
                    }
                    // M2-1: workspace 快照推送（可选）；失败 fail-closed 进入 destroy。
                    if let workspacePath = p.string("--workspace") {
                        do {
                            let snapshot = try WorkspaceSyncService.buildSnapshot(root: URL(fileURLWithPath: workspacePath))
                            let ack = try await runtime.pushWorkspace(handle, snapshot: snapshot)
                            print("ws-sync ok wsId=\(ack.wsId) files=\(snapshot.files.count) bytes=\(snapshot.totalBytes)")
                            fflush(stdout)
                            // Guest-side digest verification: sha256sum every synced file and
                            // compare against the host snapshot manifest.
                            let paths = snapshot.files.map { "/workspace/\($0.relativePath)" }
                            let digestProbe = try await runtime.ptyRoundTrip(
                                handle,
                                argv: ["/bin/sh", "-c", "busybox sha256sum \(paths.joined(separator: " "))"],
                                inputHex: nil, timeoutSeconds: 10)
                            // PTY 输出可能带 CR/CRLF；转为统一行后抽取 64-hex 摘要集合。
                            let normalized = digestProbe.stdoutText
                                .replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "\n")
                            let tokenLines: [String] = normalized.split(separator: "\n").map(String.init)
                            let tokens: [String] = tokenLines.flatMap { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
                            let guestHashes = Set(tokens.filter { $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) })
                            var mismatches: [String] = []
                            for file in snapshot.files where !guestHashes.contains(file.sha256Hex) {
                                mismatches.append(file.relativePath)
                            }
                            if mismatches.isEmpty {
                                print("ws-verify ok files=\(snapshot.files.count) (guest sha256 matches snapshot)")
                            } else {
                                print("ws-verify FAILED \(mismatches.joined(separator: ","))")
                            }
                            fflush(stdout)
                        } catch {
                            fputs("dbx-poc: workspace sync failed: \(error)\n", stderr)
                            fflush(stderr)
                        }
                    }
                    // M1-4 mainstream PTY demo path: real shell inside a real
                    // controlling terminal, output streamed back through the
                    // encrypted record channel.
                    do {
                        let ttyProbe = try await runtime.ptyRoundTrip(
                            handle, argv: ["/bin/sh", "-c", "echo DBX_PTY_MARKER; tty; id -u; exit"],
                            inputHex: nil, timeoutSeconds: 8)
                        print("pty[0]=exit\(ttyProbe.exitCode ?? -1) stdout=\(ttyProbe.stdoutText.replacingOccurrences(of: "\n", with: " | "))")
                        fflush(stdout)
                        let stdinProbe = try await runtime.ptyRoundTrip(
                            handle,
                            argv: ["/bin/sh", "-c", "read x; echo DBX_PTY_INPUT=$x; exit"],
                            inputHex: "68656c6c6f2d7074790a", timeoutSeconds: 8)
                        print("pty[1]=exit\(stdinProbe.exitCode ?? -1) stdout=\(stdinProbe.stdoutText.replacingOccurrences(of: "\n", with: " | "))")
                        fflush(stdout)
                    } catch {
                        fputs("dbx-poc: pty demo failed: \(error)\n", stderr)
                        fflush(stderr)
                    }
                    for (index, argv) in commands.enumerated() {
                        guard let exec = try? await runtime.execute(handle, request: ControlRequest(kind: .exec, argv: argv, timeoutSeconds: 3)) else {
                            print("exec[\(index)]=-1 stdout= (response unavailable)")
                            continue
                        }
                        print("exec[\(index)]=\(exec.exitCode) stdout=\(exec.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
                        if !exec.stderr.isEmpty {
                            fputs("exec[\(index)]-stderr=\(exec.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)
                            fflush(stderr)
                        }
                    }
                    fflush(stdout)
                    break
                }
                if Date() >= authenticatedDeadline {
                    fputs("dbx-poc: guest did not become authenticated before exec timeout\n", stderr)
                    fflush(stderr)
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            statusTask.cancel()
            try await runtime.stop(handle)
            try await runtime.destroy(handle)
            print("sandbox destroyed \(handle.sandboxID)")
            fflush(stdout)
            return
        } catch {
            try? await runtime.destroy(handle)
            throw error
        }
        try await runtime.stop(handle)
        try await runtime.destroy(handle)
        print("sandbox destroyed \(handle.sandboxID)")
    }

    /// M11：仅 launch 需要绝对路径，签名/publish 保留原 manifest 里的相对 URL 以保证 byte-identical 幂等。
    static func loadManifest(at url: URL) throws -> ManifestFile {
        var manifest = try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url))
        manifest.resolveRelativeURLs(from: url.deletingLastPathComponent())
        return manifest
    }

    private static func loadSignedManifestPreservingURLs(at url: URL) throws -> ManifestFile {
        try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url))
    }

    // MARK: - M22 分发

    /// 当前构建的版本信息（编译期注入，缺省 `0.0.0-dev`）。
    private static func printVersion() throws {
        struct VersionInfo: Encodable {
            let schema = "deskbox-version/v1"
            let version: String
            let build: String
            let bundleIdentifier: String
            let gitCommit: String
            let hostArchitecture: String
            let guestAssetVersion: Int
        }
        let info = VersionInfo(version: DeskBoxVersion.semver,
                               build: DeskBoxVersion.build,
                               bundleIdentifier: DeskBoxVersion.bundleIdentifier,
                               gitCommit: DeskBoxVersion.gitCommit,
                               hostArchitecture: DeskBoxVersion.hostArchitecture,
                               guestAssetVersion: DeskBoxVersion.guestAssetVersion)
        print(String(decoding: try JSONEncoder.pretty.encode(info), as: UTF8.self))
    }

    /// M23：列出已配置凭据域（fail-closed 解析；非法即报错）。
    private static func listDomains(args: [String]) throws {
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.domains)
        let asJSON = p.flag("--json")
        let root = p.string("--root").map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? DeskBoxPaths.supportRoot
        let manifestURL = root.appendingPathComponent("domains.json")
        let registry: DomainRegistry
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            registry = try DomainRegistry.load(from: manifestURL, credentialRoot: root)
        } else {
            registry = DomainRegistry(manifest: .singleDefault, credentialRoot: root)
        }
        if asJSON {
            struct Out: Encodable {
                let schema: String
                let defaultDomain: String?
                let domains: [Row]
                let source: String
            }
            struct Row: Encodable {
                let domainID: String
                let allowsEgress: Bool
                let brokerPolicyFile: String?
                let brokerCredentialsFile: String?
                let allowedSigningKeyIDs: [String]
            }
            let out = Out(
                schema: "deskbox-domains-list/v1",
                defaultDomain: registry.defaultDomain?.raw,
                domains: registry.domains.map {
                    Row(domainID: $0.domainID.raw, allowsEgress: $0.allowsEgress,
                        brokerPolicyFile: $0.brokerPolicyFile,
                        brokerCredentialsFile: $0.brokerCredentialsFile,
                        allowedSigningKeyIDs: $0.allowedSigningKeyIDs)
                },
                source: FileManager.default.fileExists(atPath: manifestURL.path) ? manifestURL.path : "builtin-single-default"
            )
            print(String(decoding: try JSONEncoder.pretty.encode(out), as: UTF8.self))
            return
        }
        print("default=\(registry.defaultDomain?.raw ?? "nil") source=\(manifestURL.path)")
        for domain in registry.domains {
            print("\(domain.domainID.raw)\tegress=\(domain.allowsEgress ? "yes" : "no")\tpolicy=\(domain.brokerPolicyFile ?? "-")\tcreds=\(domain.brokerCredentialsFile ?? "-")")
        }
    }

    /// M22：更新检查。只读 channel 公开内容，回滚/未签名/撤销 key 一律拒绝。
    private static func checkUpdate(args: [String]) throws {
        // M34：此前在没有 --channel 时取「第一个不以 -- 开头的参数」——那可能是别的选项的值
        //（`check-update --current-version 1.0` 会把 "1.0" 当成 channel 路径）。
        let p = try CLIArgs.parse(args, spec: ReleaseCLISpecs.checkUpdate)
        let channelPath = try ReleaseCLISpecs.channelPath(p)
        let current = p.string("--current-version") ?? DeskBoxVersion.semver
        let asJSON = p.flag("--json")
        let url = URL(fileURLWithPath: channelPath)
        do {
            let result = try UpdateChecker.check(channelURL: url, currentVersion: current)
            emit(result, asJSON: asJSON)
        } catch {
            let refusal = UpdateChecker.refusal(currentVersion: current, error: error)
            emit(refusal, asJSON: asJSON)
            // fail-closed：拒绝必须以非零退出码表达，避免被脚本当成「无更新」。
            exit(3)
        }
    }

    private static func emit(_ result: UpdateCheckResult, asJSON: Bool) {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) {
                print(String(decoding: data, as: UTF8.self))
                return
            }
        }
        switch result.decision {
        case .available:
            print("update available: \(result.currentVersion) -> \(result.remoteVersion ?? "?") (\(result.releaseTag ?? "?"))")
        case .upToDate:
            print("up-to-date: \(result.currentVersion)")
        case .rollback:
            print("update refused: \(result.reason ?? "unknown")")
        }
    }

    private static func sweep(args: [String]) throws {
        let cowRoot = try DaemonCLI.sweepCowRoot(args) ?? DeskBoxPaths.cowRoot
        // M20：必须经 VZRuntime.sweepOrphans，才能把崩溃残留的快照文件一起清掉
        // （直接调 registry.sweep 会留下可被 restore 的旧 VM 状态）。
        let runtime = try VZRuntime(cowRoot: cowRoot, enableConsole: false, enableControlSocket: false)
        let report = try runtime.sweepOrphans()
        print(String(decoding: try JSONEncoder.pretty.encode([
            "orphanedSandboxes": report.orphanedSandboxes.map(\.raw),
            "removedCloneFiles": report.removedCloneFiles
        ]), as: UTF8.self))
    }

    private static func printUsage() {
        print("dbx-poc capcheck")
        print("dbx-poc make-manifest --kernel <vmlinuz> --root-disk <disk> [--initrd <initrd>] [--asset-version N] --output <manifest.json>")
        print("dbx-poc gen-guest-sign-key --output-key <path>")
        print("dbx-poc sign-manifest --manifest <in> --key <path> --output <out> [--asset-version N]")
        print("dbx-poc validate-assets <manifest.json> [--allow-unsigned-manifest]")
        print("dbx-poc launch <manifest.json> [--cow-root <directory>] [--memory-mib N] [--cpus N] [--minimal-vz] [--allow-plaintext] [--allow-unsigned-manifest]")
        print("dbx-poc sweep [--cow-root <directory>]")
        print("launch is foreground; EOF stops and destroys the VM")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case exit(Int)
    var description: String { switch self { case .usage(let value): return value; case .exit(let code): return "exit code \(code)" } }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
}

struct ManifestFile: Codable {
    var kernelURL: URL
    var initrdURL: URL?
    var rootDiskURL: URL
    let kernelCommandLine: String
    let guestAssetVersion: Int
    let manifestDigest: String
    var fileDigests: [String: String]
    var signature: ManifestSignature?
    var sbomDigest: String?

    var asManifest: GuestAssetManifest {
        GuestAssetManifest(kernelURL: kernelURL, initrdURL: initrdURL, rootDiskURL: rootDiskURL,
                           kernelCommandLine: kernelCommandLine, guestAssetVersion: guestAssetVersion,
                           manifestDigest: manifestDigest, fileDigests: fileDigests,
                           signature: signature, sbomDigest: sbomDigest)
    }

    mutating func resolveRelativeURLs(from base: URL) {
        kernelURL = resolve(kernelURL, from: base)
        initrdURL = initrdURL.map { resolve($0, from: base) }
        rootDiskURL = resolve(rootDiskURL, from: base)
        // M11：fileDigests 保留以 basename 为键（ManifestFile 签名 payload 可迁移目录）；
        // GuestAssetValidator 会用 basename 查键，不再需要转为绝对路径。
    }

    private func resolve(_ value: URL, from base: URL) -> URL {
        value.isFileURL && value.path.hasPrefix("/") ? value.standardizedFileURL : base.appendingPathComponent(value.path).standardizedFileURL
    }
}

private struct LaunchOutput: Codable {
    let sandboxID: SandboxID
    let bootID: BootID
    let state: String
    let boot: BootContext
    let message: String
}

// MARK: - M12 daemon CLI glue

private extension DBXPOC {
    // M27：参数解析统一走 DaemonCLI（声明式规格 + fail-closed），这里只负责发送与打印。

    static func daemonRunCli(args: [String]) throws {
        let inv = try DaemonCLI.run(args)
        let response = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        print("run ok sandboxId=\(response.sandboxId ?? "?") state=\(response.state ?? "?")")
    }

    static func daemonPsCli(args: [String]) throws {
        let inv = try DaemonCLI.bare(args, spec: DaemonCLISpecs.ps, kind: "ps")
        let response = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        for info in response.sandboxes ?? [] {
            print("\(info.sandboxId)\t\(info.state)\t\(info.bootedAtUtc)\t\(info.manifestPath)\t\(info.domain ?? "-")")
        }
    }

    static func daemonExecCli(args: [String]) throws {
        let inv = try DaemonCLI.exec(args)
        // M41：Ctrl-C / SIGTERM → 请求 guest 取消这条命令，然后照常等应答（带回取消之前的输出）。
        // guest 不支持取消（旧资产）或取消失败时退回原来的行为：客户端立刻退出，命令在 guest 里跑到结束 / 超时。
        let interrupt = ExecInterruptHandler(sandboxId: inv.request.sandboxId, domain: inv.request.domain, sock: inv.sock)
        interrupt.install()
        let response = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        interrupt.uninstall()
        if let out = response.stdout { print(out, terminator: "") }
        if let err = response.stderr, !err.isEmpty { fputs(err + (err.hasSuffix("\n") ? "" : "\n"), stderr) }
        // M39：截断 / 不完整必须让调用方知道（此前 stdout 被静默截到 1023 字节，退出码照样是 0）。
        for notice in response.notices ?? [] { fputs("dbx-poc: 注意：\(notice)\n", stderr) }
        // 被自己的 Ctrl-C 取消：按 shell 的约定以 128 + 信号退出。
        if response.cancelled == true, let signal = interrupt.receivedSignal {
            throw CLIError.exit(128 + Int(signal))
        }
        if response.exitCode ?? 1 != 0 {
            throw CLIError.exit(Int(response.exitCode ?? 1))
        }
    }

    static func daemonStopCli(args: [String]) throws {
        let inv = try DaemonCLI.single(args, spec: DaemonCLISpecs.stop, kind: "stop")
        _ = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        print("stopped \(inv.request.sandboxId ?? "?")")
    }

    static func daemonRmCli(args: [String]) throws {
        let inv = try DaemonCLI.rm(args)
        _ = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        print("removed \(inv.request.sandboxId ?? "?")")
    }

    /// M16：restart（stop+rm+重建，新 sandboxId）
    static func daemonRestartCli(args: [String]) throws {
        let inv = try DaemonCLI.single(args, spec: DaemonCLISpecs.restart, kind: "restart")
        let resp = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        print("restarted -> \(resp.sandboxId ?? inv.request.sandboxId ?? "?")")
    }

    /// M16：console tail（guest serial 的诊断输出）。
    static func daemonConsoleCli(args: [String]) throws {
        let inv = try DaemonCLI.console(args)
        let resp = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        let hex = resp.outputHex ?? ""
        var bytes = Data()
        var j = hex.startIndex
        while j < hex.endIndex {
            bytes.append(UInt8(hex[j..<hex.index(j, offsetBy: 2)], radix: 16) ?? 0)
            j = hex.index(j, offsetBy: 2)
        }
        print(String(data: bytes, encoding: .utf8) ?? "<binary \(bytes.count)B>")
    }

    /// 通用单 id 端点（suspend / resume）。
    static func daemonSimpleCli(args: [String], kind: String, spec: CLISpec) throws {
        let inv = try DaemonCLI.single(args, spec: spec, kind: kind)
        let resp = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        print("\(kind) ok sandboxId=\(resp.sandboxId ?? inv.request.sandboxId ?? "?") state=\(resp.state ?? "?")")
    }

    /// M21：资源统计（--json 输出机器可读）。
    static func daemonStatsCli(args: [String]) throws {
        let inv = try DaemonCLI.stats(args)
        let id = inv.request.sandboxId ?? "?"
        let resp = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        guard let stats = resp.stats else {
            print("stats: 无数据")
            return
        }
        if inv.json {
            let data = try JSONEncoder().encode(stats)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        func fmt(_ v: UInt64?) -> String { v.map(String.init) ?? "null" }
        print("sandbox=\(id)")
        print("cpuUsageUsec=\(fmt(stats.cpuUsageUsec))")
        print("memoryCurrentBytes=\(fmt(stats.memoryCurrentBytes))")
        print("memoryMaxBytes=\(fmt(stats.memoryMaxBytes))")
        print("pidsCurrent=\(stats.pidsCurrent.map(String.init) ?? "null")")
        print("pidsMax=\(stats.pidsMax.map(String.init) ?? "null")")
        if let err = stats.statsError { print("statsError=\(err)") }
    }

    static func daemonShutdownCli(args: [String]) throws {
        let inv = try DaemonCLI.bare(args, spec: DaemonCLISpecs.shutdown, kind: "shutdown")
        let response = try DaemonClient.send(request: inv.request, sockPath: inv.sock)
        print("shutdown ack pid=\(response.pid ?? 0)")
    }
}

