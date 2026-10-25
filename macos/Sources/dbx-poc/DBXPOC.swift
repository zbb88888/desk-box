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
                let report = VZCapabilityProbe.probe()
                print(String(decoding: try JSONEncoder.pretty.encode(report), as: UTF8.self))
            case "verify-sbom":
                guard let first = args.dropFirst().first else { throw CLIError.usage("dbx-poc verify-sbom <sbom.json>") }
                let sbom = try GuestSbomVerifier.verify(sbomURL: URL(fileURLWithPath: first))
                print("sbom verified assetVersion=\(sbom.assetVersion) inputs=\(sbom.inputs.count) outputs=\(sbom.outputs.count)")
            case "validate-assets":
                guard let first = args.dropFirst().first else { throw CLIError.usage("dbx-poc validate-assets <manifest.json> [--allow-unsigned-manifest] [--release-keys <json>]") }
                let manifest = try loadManifest(at: URL(fileURLWithPath: first))
                if let chainPath = try optionString("--release-keys", in: args) {
                    let chainData = try Data(contentsOf: URL(fileURLWithPath: chainPath))
                    let raw = try JSONDecoder().decode(ReleaseKeyFile.self, from: chainData)
                    let chain = ReleaseKeysManifest(schema: raw.schema, generatedAtUtc: raw.generatedAtUtc, keys: raw.keys)
                    do {
                        try ManifestSigner.verify(manifest: manifest.asManifest,
                                                 chain: chain,
                                                 allowUnsignedManifest: args.contains("--allow-unsigned-manifest"))
                    } catch let error as ManifestSignerError {
                        throw SandboxFailure(.platformAssetDigestMismatch, error.description)
                    }
                    print("validated manifest \(manifest.manifestDigest) against release-keys （\(chain.keys.count) keys）")
                } else {
                    let result = try GuestAssetValidator.validate(manifest.asManifest,
                                                                  allowUnsignedManifest: args.contains("--allow-unsigned-manifest"))
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
            case "launch":
                try await launch(args: Array(args.dropFirst()))
            case "sweep":
                try sweep(args: Array(args.dropFirst()))
            case "help", "-h", "--help":
                printUsage()
            default:
                throw CLIError.usage("unknown command")
            }
        } catch {
            fputs("dbx-poc: \(error)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func genGuestSignKey(args: [String]) throws {
        guard let outputPath = try optionString("--output-key", in: args) else {
            throw CLIError.usage("dbx-poc gen-guest-sign-key --output-key <path>")
        }
        let pair = ManifestSigner.generateKeypairHex()
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("private:\(pair.privateHex)\n").write(to: output, atomically: true, encoding: .utf8)
        print("public:\(pair.publicHex)")
        print("wrote key material \(output.path)")
    }

    private static func signManifest(args: [String]) throws {
        guard let inputPath = try optionString("--manifest", in: args),
              let keyPath = try optionString("--key", in: args),
              let outputPath = try optionString("--output", in: args)
        else {
            throw CLIError.usage("dbx-poc sign-manifest --manifest <in> --key <path> --output <out> [--asset-version N]")
        }
        var manifest = try loadSignedManifestPreservingURLs(at: URL(fileURLWithPath: inputPath))
        if let version = try optionInt("--asset-version", in: args) {
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
        guard let outputPath = try optionString("--output-key", in: args) else {
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
        try ("private:\(pair.privateHex)\n").write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
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
        guard let base = try optionString("--base", in: args),
              let newKeyPath = try optionString("--new-key", in: args)
        else { throw CLIError.usage("dbx-poc rotate-release-key --base <release-keys.json> --new-key <path> [--output <out>]") }
        let outPath = try optionString("--output", in: args) ?? base
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
        guard let base = try optionString("--base", in: args),
              let keyID = try optionString("--key-id", in: args)
        else { throw CLIError.usage("dbx-poc revoke-release-key --base <release-keys.json> --key-id <id> [--output <out>]") }
        let outPath = try optionString("--output", in: args) ?? base
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
        guard let channelDirPath = try optionString("--channel", in: args) else {
            throw CLIError.usage("dbx-poc publish --channel <dir> --manifest <path> --sbom <path> --release-keys <path> [--release-tag <tag>] [--min-version-floor N]")
        }
        guard let manifestPath = try optionString("--manifest", in: args),
              let sbomPath = try optionString("--sbom", in: args),
              let releaseKeysPath = try optionString("--release-keys", in: args)
        else { throw CLIError.usage("dbx-poc publish 需 manifest/sbom/release-keys") }
        /// M11：`SOURCE_DATE_EPOCH` 如来，generatedAtUtc 顺从于它（幂等发布）。
        let releaseNow: Date = {
            if let sec = ProcessInfo.processInfo.environment["SOURCE_DATE_EPOCH"],
               let epoch = TimeInterval(sec) {
                return Date(timeIntervalSince1970: epoch)
            }
            return Date()
        }()
        let releaseTag = try optionString("--release-tag", in: args)
            ?? ISO8601DateFormatter().string(from: releaseNow)
        let floor = try optionInt("--min-version-floor", in: args) ?? 1
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
        guard let channelPath = args.first else {
            throw CLIError.usage("dbx-poc verify-channel <channel.json>")
        }
        let result = try ReleaseChannelVerifier.verify(channelURL: URL(fileURLWithPath: channelPath))
        print("verified channel tag=\(result.channel.releaseTag) assetVersion=\(result.channel.manifest.assetVersion) keys=\(result.channel.keys.count)")
    }

    private static func makeManifest(args: [String]) throws {
        guard let kernelPath = try optionString("--kernel", in: args),
              let rootDiskPath = try optionString("--root-disk", in: args),
              let outputPath = try optionString("--output", in: args)
        else {
            throw CLIError.usage("dbx-poc make-manifest --kernel <vmlinuz> --root-disk <disk> [--initrd <initrd>] --output <manifest.json>")
        }
        let kernel = URL(fileURLWithPath: kernelPath).standardizedFileURL
        let rootDisk = URL(fileURLWithPath: rootDiskPath).standardizedFileURL
        let initrd = try optionString("--initrd", in: args).map { URL(fileURLWithPath: $0).standardizedFileURL }
        let assetVersion = try optionInt("--asset-version", in: args) ?? 1
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
            sbomDigest: try optionString("--sbom-digest", in: args)
        )
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(manifest).write(to: output, options: .atomic)
        print("wrote unsigned manifest \(output.path) — sign with `dbx-poc sign-manifest` before launch")
    }

    private static func launch(args: [String]) async throws {
        guard let manifestPath = args.first else {
            throw CLIError.usage("dbx-poc launch <manifest.json> [--cow-root <directory>] [--memory-mib N] [--cpus N] [--minimal-vz]")
        }
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        let manifest = try loadManifest(at: manifestURL)
        let cowRoot = try optionURL("--cow-root", in: args)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeskBox/cows", isDirectory: true)
        let memoryMiB = try optionInt("--memory-mib", in: args) ?? 2048
        let cpus = try optionInt("--cpus", in: args) ?? 2
        guard memoryMiB > 0, cpus > 0 else {
            throw CLIError.usage("--memory-mib and --cpus must be positive")
        }

        let audit = InMemoryAuditSink()
        let diagnosticOnly = args.contains("--minimal-vz")
        // M1-2: the encrypted record channel is on by default. `--allow-plaintext`
        // is an explicit downgrade switch kept for guest-side debugging only.
        // M1-5: `--allow-unsigned-manifest` is the manifest-side twin of that flag.
        let plaintextAllowed = args.contains("--allow-plaintext")
        let unsignedAllowed = args.contains("--allow-unsigned-manifest")
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
                    if let brokerURLString = try optionString("--broker-preload", in: args),
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
                    if let guestBrokerURL = try optionString("--broker-guest-url", in: args) {
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
                    if let bundlePath = try optionString("--oci-bundle", in: args) {
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
                    if let workspacePath = try optionString("--workspace", in: args) {
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
    private static func loadManifest(at url: URL) throws -> ManifestFile {
        var manifest = try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url))
        manifest.resolveRelativeURLs(from: url.deletingLastPathComponent())
        return manifest
    }

    private static func loadSignedManifestPreservingURLs(at url: URL) throws -> ManifestFile {
        try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url))
    }

    private static func optionString(_ name: String, in args: [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw CLIError.usage("missing value for \(name)") }
        return args[index + 1]
    }

    private static func optionURL(_ name: String, in args: [String]) throws -> URL? {
        try optionString(name, in: args).map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private static func optionInt(_ name: String, in args: [String]) throws -> Int? {
        guard let value = try optionString(name, in: args) else { return nil }
        guard let int = Int(value) else { throw CLIError.usage("invalid value for \(name)") }
        return int
    }

    private static func sweep(args: [String]) throws {
        let cowRoot = try optionURL("--cow-root", in: args)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeskBox/cows", isDirectory: true)
        let registry = try SandboxRegistry(root: cowRoot)
        let report = try registry.sweep()
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

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let value) = self { return value }; return "usage error" }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
}

private struct ManifestFile: Codable {
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
