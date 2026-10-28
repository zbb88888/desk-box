import Foundation

/// M22：构建期注入的版本信息（由 scripts/package-app.sh 生成，勿手工编辑）。
public enum DeskBoxVersion {
    public static let semver: String = "0.2.0"
    public static let build: String = "174"
    public static let bundleIdentifier: String = "com.deskbox.gui"
    public static let gitCommit: String = "a43ed28"
    public static let guestAssetVersion: Int = 1

    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
