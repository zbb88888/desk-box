import Foundation

/// M22：app bundle 内的路径解析。
///
/// 分发版布局（见 docs/design/m22-distribution-notarization.md §3）：
/// ```
/// DeskBox.app/Contents/MacOS/DeskBoxGUI
/// DeskBox.app/Contents/MacOS/dbx-poc          <- helper 与 GUI 同目录，同一签名 scope
/// DeskBox.app/Contents/Resources/guest/*      <- guest 资产与 manifest/channel
/// ```
/// 开发版（`gui/dist/DeskBox.app`）仍然回退到仓库内 `.build/release/dbx-poc` 与 `guest/`。
enum BundlePaths {
    /// helper 可执行文件路径。
    static func dbxPOC(override: String = "") -> String? {
        if !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // 1) 分发包：与 GUI 同目录（Contents/MacOS/dbx-poc）
        if let macosDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let embedded = macosDir.appendingPathComponent("dbx-poc").path
            if FileManager.default.isExecutableFile(atPath: embedded) { return embedded }
        }
        // 2) 开发包：gui/dist/DeskBox.app → macos/.build/release/dbx-poc
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()   // dist/
            .deletingLastPathComponent()   // gui/
            .deletingLastPathComponent()   // macos/
        let viaBuild = bundleRoot.appendingPathComponent(".build/release/dbx-poc").path
        if FileManager.default.isExecutableFile(atPath: viaBuild) { return viaBuild }
        let viaCwd = FileManager.default.currentDirectoryPath + "/.build/release/dbx-poc"
        if FileManager.default.isExecutableFile(atPath: viaCwd) { return viaCwd }
        return nil
    }

    /// guest 资源目录（manifest.json / channel.json / 磁盘镜像）。
    static func guestResource(_ name: String, repoRelative: String) -> String? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("guest/\(name)").path,
           FileManager.default.fileExists(atPath: res) {
            return res
        }
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let viaRepo = bundleRoot.appendingPathComponent(repoRelative).path
        if FileManager.default.fileExists(atPath: viaRepo) { return viaRepo }
        let viaCwd = FileManager.default.currentDirectoryPath + "/" + repoRelative
        if FileManager.default.fileExists(atPath: viaCwd) { return viaCwd }
        return nil
    }

    static var defaultManifestPath: String {
        guestResource("manifest.json", repoRelative: "guest/manifest.json")
            ?? FileManager.default.currentDirectoryPath + "/guest/manifest.json"
    }

    static var defaultChannelPath: String? {
        guestResource("channel.json", repoRelative: "guest/channel.json")
    }
}
