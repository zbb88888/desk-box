import DeskBoxVZ
import Foundation

/// M34：签名 / 发布 / 校验 / 直启类子命令的参数规格。
///
/// M27 只把 daemon 生命周期子命令迁到了声明式解析；这些命令仍在用手写的 `optionString`：
/// 缺值会报错，但**未知选项被静默忽略**，值可以是另一个选项，整数不校验范围。
/// 对供应链相关的命令，静默忽略一个拼错的选项会直接放宽安全门槛：
/// - `publish --min-version-flor 5` → 防回滚下限悄悄变回默认的 1；
/// - `sign-manifest --asset-versoin 7` → 用旧版本号签名；
/// - `rotate-release-key --ouput new.json` → 原地覆盖 `--base`；
/// - `check-update --current-versoin 0.1.0` → 用内置版本比较。
enum ReleaseCLISpecs {
    static let capcheck = CLISpec(command: "capcheck", usage: "dbx-poc capcheck")
    static let version = CLISpec(command: "version", usage: "dbx-poc version")

    static let verifySbom = CLISpec(command: "verify-sbom", usage: "dbx-poc verify-sbom <sbom.json>",
                                    positionals: ["sbom path"])

    static let validateAssets = CLISpec(
        command: "validate-assets",
        usage: "dbx-poc validate-assets <manifest.json> [--allow-unsigned-manifest] [--release-keys <json>]",
        positionals: ["manifest path"], valueOptions: ["--release-keys"], flags: ["--allow-unsigned-manifest"])

    static let makeManifest = CLISpec(
        command: "make-manifest",
        usage: "dbx-poc make-manifest --kernel <vmlinuz> --root-disk <disk> [--initrd <initrd>] [--asset-version N] [--sbom-digest <sha256>] --output <manifest.json>",
        valueOptions: ["--kernel", "--root-disk", "--initrd", "--asset-version", "--sbom-digest", "--output"])

    static let genGuestSignKey = CLISpec(command: "gen-guest-sign-key",
                                         usage: "dbx-poc gen-guest-sign-key --output-key <path> [--force]",
                                         valueOptions: ["--output-key"], flags: ["--force"])

    static let signManifest = CLISpec(
        command: "sign-manifest",
        usage: "dbx-poc sign-manifest --manifest <in> --key <path> --output <out> [--asset-version N]",
        valueOptions: ["--manifest", "--key", "--output", "--asset-version"])

    static let genReleaseKey = CLISpec(command: "gen-release-key",
                                       usage: "dbx-poc gen-release-key --output-key <path> [--force]",
                                       valueOptions: ["--output-key"], flags: ["--force"])

    static let rotateReleaseKey = CLISpec(
        command: "rotate-release-key",
        usage: "dbx-poc rotate-release-key --base <release-keys.json> --new-key <path> [--output <out>]",
        valueOptions: ["--base", "--new-key", "--output"])

    static let revokeReleaseKey = CLISpec(
        command: "revoke-release-key",
        usage: "dbx-poc revoke-release-key --base <release-keys.json> --key-id <id> [--output <out>]",
        valueOptions: ["--base", "--key-id", "--output"])

    static let publish = CLISpec(
        command: "publish",
        usage: "dbx-poc publish --channel <dir> --manifest <path> --sbom <path> --release-keys <path> [--release-tag <tag>] [--min-version-floor N]",
        valueOptions: ["--channel", "--manifest", "--sbom", "--release-keys", "--release-tag", "--min-version-floor"])

    static let verifyChannel = CLISpec(command: "verify-channel", usage: "dbx-poc verify-channel <channel.json>",
                                       positionals: ["channel path"])

    static let domains = CLISpec(command: "domains", usage: "dbx-poc domains [--root <dir>] [--json]",
                                 valueOptions: ["--root"], flags: ["--json"])

    /// channel 既可以用 `--channel` 给，也可以作为唯一的位置参数给（二者只能取其一）。
    static let checkUpdate = CLISpec(
        command: "check-update",
        usage: "dbx-poc check-update --channel <channel.json> [--current-version <semver>] [--json]",
        optionalPositionals: ["channel path"],
        valueOptions: ["--channel", "--current-version"], flags: ["--json"])

    static let launch = CLISpec(
        command: "launch",
        usage: "dbx-poc launch <manifest.json> [--cow-root <directory>] [--memory-mib N] [--cpus N] [--minimal-vz] [--graphics] [--allow-plaintext] [--allow-unsigned-manifest] [--workspace dir] [--oci-bundle b] [--broker-preload url] [--broker-guest-url url]",
        positionals: ["manifest path"],
        valueOptions: ["--cow-root", "--memory-mib", "--cpus", "--workspace", "--oci-bundle", "--broker-preload", "--broker-guest-url"],
        flags: ["--minimal-vz", "--graphics", "--allow-plaintext", "--allow-unsigned-manifest"])

    static let all: [CLISpec] = [capcheck, version, verifySbom, validateAssets, makeManifest, genGuestSignKey,
                                 signManifest, genReleaseKey, rotateReleaseKey, revokeReleaseKey, publish,
                                 verifyChannel, domains, checkUpdate, launch]

    /// 版本号类整数的允许范围（拒绝负数与非数字；0 保留给「未设置」语义的旧数据）。
    static let versionRange = 0...Int(Int32.max)

    /// `check-update` 的 channel 路径：`--channel` 与位置参数二选一。
    static func channelPath(_ parsed: CLIParsed) throws -> String {
        switch (parsed.string("--channel"), parsed.optionalPositional(0)) {
        case (let option?, nil): return option
        case (nil, let positional?): return positional
        case (nil, nil):
            throw CLIError.usage("check-update: channel path required | usage: \(checkUpdate.usage)")
        case (.some, .some(let extra)):
            throw CLIError.usage("check-update: unexpected argument '\(extra)' (channel already given via --channel)")
        }
    }
}

/// M34：私钥文件以 0600 原子写入。
///
/// 此前 `gen-guest-sign-key` / `gen-release-key` 用默认权限写私钥（umask 022 下是 0644，
/// 同机任何用户可读）。这里先在同目录建一个 0600 的临时文件，写完再 rename 覆盖目标——
/// 目标路径上任何时刻都不会出现「内容已是私钥、权限还没收紧」的窗口。
enum PrivateKeyFile {
    static let existsCode = "DBX-KEY-EXISTS"

    /// M45：生成密钥前检查目标是否已存在（纯判定；`exists` 由调用方给出）。
    /// 此前直接覆盖：对着现有的签名私钥再跑一次 gen-*-key，旧私钥就没了——用它签过的 manifest /
    /// 发布链从此无法再续签，而命令没有任何提示。
    static func overwriteRefusal(path: String, exists: Bool, force: Bool) -> String? {
        guard exists, !force else { return nil }
        return "\(existsCode): \(path) 已经存在。覆盖它会丢失现有的私钥（用它签名的资产将无法再续签 / 轮换）。"
            + "换一个输出路径，或确认不再需要旧密钥后加 --force。"
    }

    static func write(_ content: String, to url: URL, force: Bool) throws {
        // 符号链接本身也算「存在」（不跟随）：指向别处的悬空链接同样不能被悄悄替换。
        let exists = (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
        if let refusal = overwriteRefusal(path: url.path, exists: exists, force: force) {
            throw CLIError.usage(refusal)
        }
        try write(content, to: url)
    }

    static func write(_ content: String, to url: URL) throws {
        // M35：统一走 DeskBoxVZ.SecureFile（同一套实现也用于快照密钥、快照、沙箱盘域标记）。
        // 私钥所在目录若需要新建，同样是 0700。
        do { try SecureFile.write(Data(content.utf8), to: url) }
        catch { throw CLIError.usage("cannot write key material to \(url.path): \(error.localizedDescription)") }
    }
}
