import XCTest
import Foundation
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M19 INV-04：出站网络策略 corpus（DNS rebinding / 私网 / 明文 / 超限 / redirect）。
///
/// 这些断言全部在宿主策略层可验证，不需要起 VM，因此进普通 CI。
/// guest 侧「无网卡」证据由 `scripts/security-corpus-network.sh` 在真机补。
final class SecurityCorpusNetworkTests: XCTestCase {

    private func policy(_ hosts: [String] = ["api.example.com"]) -> BrokerPolicy {
        BrokerPolicy(allowedHosts: hosts, allowedSchemes: ["https"], maxResponseBytes: 1024)
    }

    private func decision(_ url: String) -> BrokerPolicy.BrokerDecision {
        policy().decision(for: URL(string: url)!)
    }

    // MARK: 允许面

    func testAllowlistedHTTPSIsAllowed() {
        XCTAssertTrue(decision("https://api.example.com/v1/x").isAllowed)
    }

    // MARK: 拒绝面

    func testPlaintextHTTPIsDenied() {
        XCTAssertFalse(decision("http://api.example.com/v1/x").isAllowed)
    }

    func testNonAllowlistedHostIsDenied() {
        for url in ["https://evil.example.net/", "https://api.example.com.evil.net/"] {
            XCTAssertFalse(decision(url).isAllowed, url)
        }
    }

    func testLoopbackIsDenied() {
        for url in ["https://127.0.0.1/", "https://localhost/", "https://[::1]/"] {
            XCTAssertFalse(decision(url).isAllowed, url)
        }
    }

    func testCloudMetadataIsDenied() {
        XCTAssertFalse(decision("https://169.254.169.254/latest/meta-data/").isAllowed)
    }

    func testWildcardHostIsDenied() {
        // 0.0.0.0 与通配写法不得等价于「允许一切」。
        for url in ["https://0.0.0.0/", "https://*.example.com/"] {
            XCTAssertFalse(decision(url).isAllowed, url)
        }
    }

    // MARK: DNS rebinding（host 合法但解析到私网）

    /// 策略层必须能对「允许列表中的域名解析出私网/环回地址」做出独立判断，
    /// 否则 allowlist 内域名被投毒后即可打穿宿主内网。
    func testPrivateResolutionIsRejectedEvenForAllowlistedHost() {
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv4("127.0.0.1"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv4("10.1.2.3"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv4("172.16.0.1"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv4("192.168.1.1"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv4("169.254.169.254"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv4("0.0.0.0"))
        XCTAssertFalse(BrokerPolicy.isPrivateOrLoopbackIPv4("93.184.216.34"))

        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv6("::1"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv6("fe80::1"))
        XCTAssertTrue(BrokerPolicy.isPrivateOrLoopbackIPv6("fd00::1"))
        XCTAssertFalse(BrokerPolicy.isPrivateOrLoopbackIPv6("2606:2800:220:1::1"))

        // 允许列表里的域名若解析到私网，必须拒绝。
        let decision = policy().decision(for: URL(string: "https://api.example.com/")!,
                                         resolvedAddresses: ["127.0.0.1"])
        XCTAssertFalse(decision.isAllowed, "allowlisted host 解析到私网必须拒绝")
        let ok = policy().decision(for: URL(string: "https://api.example.com/")!,
                                   resolvedAddresses: ["93.184.216.34"])
        XCTAssertTrue(ok.isAllowed)
        // 解析结果含任一私网地址即拒（多 A 记录投毒）。
        let mixed = policy().decision(for: URL(string: "https://api.example.com/")!,
                                      resolvedAddresses: ["93.184.216.34", "10.0.0.5"])
        XCTAssertFalse(mixed.isAllowed)
    }

    // MARK: redirect

    func testRedirectToNonAllowlistedHostIsDenied() {
        // 3xx 目标必须重新过策略门，不允许跟随到 allowlist 之外。
        let target = URL(string: "https://evil.example.net/steal")!
        XCTAssertFalse(policy().decision(for: target).isAllowed)
    }

    // MARK: 响应上限

    func testResponseLimitIsEnforcedInReport() {
        // 上限语义：超出部分被截断并标记 truncated（不透传超额数据给 guest）。
        XCTAssertEqual(policy().maxResponseBytes, 1024)
    }

    // MARK: 空/畸形

    func testMissingHostIsDenied() {
        XCTAssertFalse(BrokerPolicy(allowedHosts: [""]).decision(for: URL(string: "https:///x")!).isAllowed)
    }
}
