import XCTest
import Darwin
import Foundation
@testable import DeskBoxGUI

/// 假 daemon：监听 UNIX socket；`reply` 为 nil 时 accept 后一言不发（模拟「活着但正忙」）。
final class FakeDaemon: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var stopped = false
    private var _requests: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(path: String, reply: String?) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) } } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(rc == 0, "bind errno=\(errno)")
        listen(fd, 16)
        Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                lock.lock(); clients.append(c); let done = stopped; lock.unlock()
                if done { break }
                guard let reply else { continue }   // 沉默：保持连接不回话
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(c, &buf, buf.count)
                if n > 0 { lock.lock(); _requests.append(String(decoding: buf[0..<n], as: UTF8.self)); lock.unlock() }
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            }
        }.start()
    }

    func stop() {
        lock.lock(); stopped = true; let cs = clients; clients = []; lock.unlock()
        for c in cs { close(c) }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}


/// 让主队列上的回调得以执行，直到条件成立或超时。
func spinMainRunLoop(until condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

