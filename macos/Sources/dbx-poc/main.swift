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

    private static func launch(args: [String]) async throws {
        guard let manifestPath = args.first else {
            throw CLIError.usage("dbx-poc launch <manifest.json> [--cow-root <directory>] [--memory-mib N] [--cpus N]")
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
        let runtime = try VZRuntime(cowRoot: cowRoot, audit: audit)
        let sandboxID = SandboxID.new()
        let workload = WorkloadSpec(
            entrypoint: ["/bin/sh"],
            args: [],
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/home/sandbox"],
            workingDirectory: "/",
            declaredPorts: [],
            uid: 65_534,
            gid: 65_534,
            volumes: [],
            resources: ResourceHints(cpuCount: cpus, memoryMiB: memoryMiB)
        )
        let request = SandboxCreateRequest(
            sandboxID: sandboxID,
            workspaceID: .new(),
            correlationID: UUID(),
            workloadDigest: "sha256:local-poc",
            workload: workload,
            guestAssets: manifest.asManifest,
            resources: ResourceHints(cpuCount: cpus, memoryMiB: memoryMiB),
            networking: .none
        )

        let handle = try await runtime.create(request)
        do {
            let boot = try await runtime.start(handle)
            let output = LaunchOutput(
                sandboxID: handle.sandboxID,
                bootID: handle.bootID,
                state: "pending-bootstrap",
                boot: boot,
                message: "VM 已启动；等待 guest bootstrap proof。输入 EOF 或 Ctrl-C 结束。"
            )
            print(String(decoding: try JSONEncoder.pretty.encode(output), as: UTF8.self))
            fflush(stdout)
            // 当前阶段没有 guest execd/控制通道客户端；保持宿主进程存活，
            // 确保 VM 与 COW 的所有权不脱离 runtime。EOF 后安全回收。
            while readLine(strippingNewline: true) != nil {}
        } catch {
            try? await runtime.destroy(handle)
            throw error
        }
        try await runtime.stop(handle)
        try await runtime.destroy(handle)
        print("sandbox destroyed \(handle.sandboxID)")
    }

    private static func loadManifest(at url: URL) throws -> ManifestFile {
        let data = try Data(contentsOf: url)
        var manifest = try JSONDecoder().decode(ManifestFile.self, from: data)
        let base = url.deletingLastPathComponent()
        manifest.resolveRelativeURLs(from: base)
        return manifest
    }

    private static func optionURL(_ name: String, in args: [String]) throws -> URL? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw CLIError.usage("missing value for \(name)") }
        return URL(fileURLWithPath: args[index + 1]).standardizedFileURL
    }

    private static func optionInt(_ name: String, in args: [String]) throws -> Int? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count, let value = Int(args[index + 1]) else {
            throw CLIError.usage("invalid value for \(name)")
        }
        return value
    }

    private static func printUsage() {
        print("dbx-poc capcheck")
        print("dbx-poc validate-assets <manifest.json>")
        print("dbx-poc launch <manifest.json> [--cow-root <directory>] [--memory-mib N] [--cpus N]")
        print("")
        print("launch keeps the VM in the foreground; EOF/Ctrl-C stops and destroys it.")
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case .usage(let message): return message }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
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
        GuestAssetManifest(
            kernelURL: kernelURL,
            initrdURL: initrdURL,
            rootDiskURL: rootDiskURL,
            kernelCommandLine: kernelCommandLine,
            guestAssetVersion: guestAssetVersion,
            manifestDigest: manifestDigest,
            fileDigests: fileDigests
        )
    }

    mutating func resolveRelativeURLs(from base: URL) {
        kernelURL = resolve(kernelURL, from: base)
        initrdURL = initrdURL.map { resolve($0, from: base) }
        rootDiskURL = resolve(rootDiskURL, from: base)

        var normalizedDigests: [String: String] = [:]
        for (path, digest) in fileDigests {
            let url = resolve(URL(fileURLWithPath: path), from: base)
            normalizedDigests[url.path] = digest
        }
        fileDigests = normalizedDigests
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
