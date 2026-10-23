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
                let data = try JSONEncoder.pretty.encode(report)
                print(String(decoding: data, as: UTF8.self))
            case "validate-assets":
                guard args.count == 2 else { throw CLIError.usage("dbx-poc validate-assets <manifest.json>") }
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                let manifest = try JSONDecoder().decode(ManifestFile.self, from: data)
                let result = try GuestAssetValidator.validate(manifest.asManifest)
                print("validated manifest \(result.manifestDigest)")
            case "help", "-h", "--help":
                print("dbx-poc capcheck")
                print("dbx-poc validate-assets <manifest.json>")
            default:
                throw CLIError.usage("unknown command")
            }
        } catch {
            fputs("dbx-poc: \(error)\n", stderr)
            Foundation.exit(2)
        }
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
    let kernelURL: URL
    let initrdURL: URL?
    let rootDiskURL: URL
    let kernelCommandLine: String
    let guestAssetVersion: Int
    let manifestDigest: String
    let fileDigests: [String: String]

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
}
