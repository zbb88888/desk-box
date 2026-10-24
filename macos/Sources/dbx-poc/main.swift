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
            case "validate-assets":
                guard args.count == 2 else { throw CLIError.usage("dbx-poc validate-assets <manifest.json>") }
                let manifest = try loadManifest(at: URL(fileURLWithPath: args[1]))
                let result = try GuestAssetValidator.validate(manifest.asManifest)
                print("validated manifest \(result.manifestDigest)")
            case "make-manifest":
                try makeManifest(args: Array(args.dropFirst()))
            case "launch":
                try await launch(args: Array(args.dropFirst()))
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
        let files = [kernel] + (initrd.map { [$0] } ?? []) + [rootDisk]
        for file in files where !FileManager.default.isReadableFile(atPath: file.path) {
            throw CLIError.usage("asset is not readable: \(file.path)")
        }
        var digests: [String: String] = [:]
        for file in files { digests[file.path] = try AssetDigest.sha256Hex(of: file) }
        let manifest = ManifestFile(
            kernelURL: kernel,
            initrdURL: initrd,
            rootDiskURL: rootDisk,
            kernelCommandLine: "console=hvc0 root=/dev/vda rw init=/init",
            guestAssetVersion: 1,
            manifestDigest: "unsigned-local-manifest",
            fileDigests: digests
        )
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(manifest).write(to: output, options: .atomic)
        print("wrote unsigned manifest \(output.path)")
        print("manifest signing and downgrade protection are still required before release")
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
        let runtime = try VZRuntime(
            cowRoot: cowRoot,
            audit: audit,
            enableConsole: !diagnosticOnly,
            enableControlSocket: !diagnosticOnly
        )
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
            let execDeadline = Date().addingTimeInterval(15)
            while true {
                let status = try await runtime.inspect(handle)
                if status.bootstrap == .authenticated && status.state == .running {
                    let exec = try await runtime.execute(handle, request: ControlRequest(kind: .exec, argv: ["/bin/echo", "deskbox-mvp-ok"], timeoutSeconds: 5))
                    print("exec=\(exec.exitCode) stdout=\(exec.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
                    fflush(stdout)
                    break
                }
                if Date() >= execDeadline {
                    fputs("dbx-poc: guest did not become authenticated before exec timeout\n", stderr)
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let lifetime = ProcessLifetime { data in
                Task { try? await runtime.sendConsoleInput(handle, data: data) }
            }
            let reason = await lifetime.wait()
            statusTask.cancel()
            switch reason {
            case .stdinEOF:
                print("shutdown requested by stdin EOF")
            case .signal(let signal):
                print("shutdown requested by signal \(signal)")
            }
        } catch {
            try? await runtime.destroy(handle)
            throw error
        }
        try await runtime.stop(handle)
        try await runtime.destroy(handle)
        print("sandbox destroyed \(handle.sandboxID)")
    }

    private static func loadManifest(at url: URL) throws -> ManifestFile {
        var manifest = try JSONDecoder().decode(ManifestFile.self, from: Data(contentsOf: url))
        manifest.resolveRelativeURLs(from: url.deletingLastPathComponent())
        return manifest
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

    private static func printUsage() {
        print("dbx-poc capcheck")
        print("dbx-poc make-manifest --kernel <vmlinuz> --root-disk <disk> [--initrd <initrd>] --output <manifest.json>")
        print("dbx-poc validate-assets <manifest.json>")
        print("dbx-poc launch <manifest.json> [--cow-root <directory>] [--memory-mib N] [--cpus N] [--minimal-vz]")
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

    var asManifest: GuestAssetManifest {
        GuestAssetManifest(kernelURL: kernelURL, initrdURL: initrdURL, rootDiskURL: rootDiskURL,
                           kernelCommandLine: kernelCommandLine, guestAssetVersion: guestAssetVersion,
                           manifestDigest: manifestDigest, fileDigests: fileDigests)
    }

    mutating func resolveRelativeURLs(from base: URL) {
        kernelURL = resolve(kernelURL, from: base)
        initrdURL = initrdURL.map { resolve($0, from: base) }
        rootDiskURL = resolve(rootDiskURL, from: base)
        var normalized: [String: String] = [:]
        for (path, digest) in fileDigests { normalized[resolve(URL(fileURLWithPath: path), from: base).path] = digest }
        fileDigests = normalized
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
