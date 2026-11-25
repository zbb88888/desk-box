import Foundation

/// M50：Manifests 面板的数据（纯逻辑，可单元测试）。
///
/// 此前扫描逻辑写在视图里，有三个问题：
/// - Digest 一列永远是 "-"：代码去读 `signature.payloadDigest`，而 manifest 的签名里只有 alg / keyID / sig；
/// - 目录里任何 `manifest*.json` 都列出来并给一个可点的 Run，包括解析不了的、引用的资产文件已经不在的；
/// - 没法测试。
struct ManifestCatalogRow: Identifiable, Equatable {
    enum Status: Equatable {
        case ready
        /// 没有签名：daemon 默认会拒绝（需要显式允许未签名）。照样可以点 Run，结果由 daemon 说了算。
        case unsigned
        /// 引用的资产文件不在 manifest 旁边。
        case missingAssets([String])
        /// 不是合法的 manifest JSON。
        case unreadable(String)
    }

    var id: String { path }
    let name: String
    let path: String
    let sizeBytes: Int
    /// 签名密钥的 keyID（未签名为 nil）。
    let keyID: String?
    /// 内核文件名（manifest 的 kernelURL）。
    let kernel: String?
    let assetVersion: Int?
    let status: Status

    /// Run 是否可点。未签名的照样可点（是否放行是 daemon 的策略）；读不了 / 缺资产的点了也只会失败。
    var isRunnable: Bool {
        switch status {
        case .ready, .unsigned: return true
        case .missingAssets, .unreadable: return false
        }
    }

    /// 状态列的文字。
    var statusText: String {
        switch status {
        case .ready: return "signed"
        case .unsigned: return "unsigned"
        case .missingAssets(let names): return "missing: " + names.joined(separator: ", ")
        case .unreadable(let why): return "unreadable: \(why)"
        }
    }

    /// 签名列的文字：keyID；未签名 / 读不了时为 "-"。
    var signatureText: String { keyID ?? "-" }
}

enum ManifestCatalog {
    /// 目录下哪些文件算 manifest：`manifest*.json`。
    /// `*.unsigned.json` 是签名前的中间产物（旁边总有对应的已签名版本），不列出。
    static func isManifestFileName(_ name: String) -> Bool {
        name.hasPrefix("manifest") && name.hasSuffix(".json") && !name.hasSuffix(".unsigned.json")
    }

    /// 扫描目录。目录不存在 / 不可读时返回空列表。按文件名排序。
    static func scan(directory: URL, fileManager: FileManager = .default) -> [ManifestCatalogRow] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter(isManifestFileName).sorted().map { row(name: $0, directory: directory, fileManager: fileManager) }
    }

    static func row(name: String, directory: URL, fileManager: FileManager = .default) -> ManifestCatalogRow {
        let url = directory.appendingPathComponent(name)
        let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        func unreadable(_ why: String) -> ManifestCatalogRow {
            ManifestCatalogRow(name: name, path: url.path, sizeBytes: size, keyID: nil, kernel: nil,
                               assetVersion: nil, status: .unreadable(why))
        }
        // manifest 很小；超过 1MiB 的肯定不是，不往内存里读。
        guard size <= 1_048_576 else { return unreadable("too large") }
        guard let data = try? Data(contentsOf: url) else { return unreadable("cannot read") }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return unreadable("not JSON") }
        guard let digests = object["fileDigests"] as? [String: Any], !digests.isEmpty,
              let kernel = object["kernelURL"] as? String else { return unreadable("not a manifest") }
        let keyID = (object["signature"] as? [String: Any])?["keyID"] as? String
        let version = (object["guestAssetVersion"] as? NSNumber)?.intValue
        // 资产必须是 manifest 旁边的普通文件名（daemon 同样只接受相对文件名）；带路径分隔符的直接算缺失。
        let missing = digests.keys.sorted().filter { asset in
            asset.contains("/") || asset == ".." || !fileManager.fileExists(atPath: directory.appendingPathComponent(asset).path)
        }
        let status: ManifestCatalogRow.Status
        if !missing.isEmpty { status = .missingAssets(missing) }
        else if keyID == nil { status = .unsigned }
        else { status = .ready }
        return ManifestCatalogRow(name: name, path: url.path, sizeBytes: size, keyID: keyID, kernel: kernel,
                                  assetVersion: version, status: status)
    }
}

/// M50：菜单栏弹窗里每个沙箱的操作（纯逻辑）。
///
/// 此前弹窗对任何状态都给 stop / rm 两个链接，直接往 socket 发请求并吞掉错误：对 suspended / failed 的
/// 沙箱点 stop 只会被 daemon 拒绝，而界面上什么都不发生。现在与主列表共用同一份「按状态启用」的规则，
/// 只是弹窗里不放需要打开面板的操作（Terminal / Console / Exec）。
enum MenuBarSandboxActions {
    static let offered: [SandboxAction] = [.stop, .resume, .restart, .rm]

    static func available(forState state: String) -> [SandboxAction] {
        SandboxRowActions.available(forState: state).filter(offered.contains)
    }
}
