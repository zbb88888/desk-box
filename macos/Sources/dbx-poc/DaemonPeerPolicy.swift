import Darwin
import Foundation

/// M35：daemon socket 的对端身份检查（纵深防御）。
///
/// 第一道防线仍然是 socket 文件的 0600 权限（bind 之后、listen 之前就已收紧，
/// 而未 listen 的 socket 无法被 connect，所以没有窗口期）。这里再加一道与文件权限无关的检查：
/// 用 `getpeereid` 取对端的有效 uid，只接受 daemon 自己的用户与 root。
/// 它覆盖的是「socket 文件权限被外部改宽 / 被放进带 ACL 的目录」这类配置失误。
enum DaemonPeerPolicy {
    /// root 被允许：它本来就能以任何方式接管这个进程，拒绝它没有安全收益，只会让 `sudo` 排障失败。
    static func allows(peerUID: uid_t, daemonUID: uid_t) -> Bool {
        peerUID == daemonUID || peerUID == 0
    }

    /// 取已连接 socket 对端的有效 uid；失败返回 nil（调用方按拒绝处理）。
    static func peerUID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// fail-closed：取不到对端身份也拒绝。
    static func admits(fd: Int32, daemonUID: uid_t = geteuid()) -> Bool {
        guard let peer = peerUID(of: fd) else { return false }
        return allows(peerUID: peer, daemonUID: daemonUID)
    }
}
