import CryptoKit
import XCTest
@testable import DeskBoxCore
@testable import DeskBoxVZ

/// M4：Swift 称的纹理 Fuzz（doc：macos/docs/design/m4-fuzz-hardening.md）。
/// 目标值都的均衡 guarantee：不 crash、不非预期空指针提就、不ưởng过面资源；对有效乘法的合法解码要经罗
/// 检查 subset 比对。
final class SwiftFuzzTests: XCTestCase {
    private var rngState: UInt64 = 0x9e3779b97f4a7c15

    private func next() -> UInt64 {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        return rngState
    }

    private func makeValidFrame() throws -> ControlFrame {
        try ControlFrame(kind: .request, sequence: 42,
                         requestID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                         payload: Data("{\"x\":1}".utf8))
    }

    func testControlFrameMutationsDoNotCrash() throws {
        let valid = try makeValidFrame().encoded()
        enum Contract { static let decoder = ControlFrameDecoder() }
        for round in 0..<20_000 {
            var bytes = valid
            let flips = 1 + Int(next() % 8)
            byteLoop: for _ in 0..<flips {
                if bytes.isEmpty { break byteLoop }
                let pos = Int(next() % UInt64(bytes.count))
                bytes[pos] = UInt8(next() & 0xff)
            }
            do {
                var decoder = ControlFrameDecoder()
                _ = try decoder.append(Data(bytes))
            } catch { /* 拒绝是合法的——这里只证不 crash */ }
        }
    }

    func testControlFrameTamperedMagicRejected() throws {
        var bytes = try makeValidFrame().encoded()
        bytes[0] ^= 0xff
        var decoder = ControlFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data(bytes)))
    }

    func testControlFrameTruncatedTailEmitsNoFrame() throws {
        let full = try makeValidFrame().encoded()
        let truncated = full.dropLast(2)  // 这个帧洞缺两字节；不能配置出完整 frame
        var decoder = ControlFrameDecoder()
        let frames = try decoder.append(Data(truncated))
        XCTAssertEqual(frames.count, 0)
    }

    func testJsonDecodersRejectGarbage() throws {
        let trailerGarbage = Data("{\"x\":1}".utf8) + Data([0x00, 0xff, 0xfe])
        _ = try? JSONDecoder().decode(GuestSbom.self, from: trailerGarbage)
        let empty = Data()
        XCTAssertThrowsError(try JSONDecoder().decode(GuestSbom.self, from: empty))
        XCTAssertThrowsError(try JSONDecoder().decode(ManifestSignature.self, from: empty))
        XCTAssertThrowsError(try JSONDecoder().decode(WsAckEvent.self, from: empty))
    }

    func testOciPolicyAdversarialCombinationsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbox-oci-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rootfs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 期望表：项目都应拒；`LANG=` 空值是接受面（环境变量可以带空值）。
        let cases: [(env: [String], expectThrow: Bool)] = [
            (["DBX_X=evil"], true),
            (["PATH=/evil"], true),
            (["HOME=/tmp"], true),
            (["USER=root"], true),
            (["9LANG=1"], true),
            (["LANG="], false),
            (["LANG=" + String(repeating: "x", count: 200)], true),
        ]
        for (env, expectThrow) in cases {
            let spec = OciRuntimeSpec(
                ociVersion: "1.0.2",
                root: OciRuntimeSpec.Root(path: "rootfs"),
                process: OciRuntimeSpec.Process(args: ["/workspace/x.sh"], cwd: "/workspace", env: env)
            )
            if expectThrow {
                XCTAssertThrowsError(try OciPolicyValidator.validate(spec: spec, bundleDir: root), "expected rejection for \(env[0])")
            } else {
                XCTAssertNoThrow(try OciPolicyValidator.validate(spec: spec, bundleDir: root), "expected acceptance for \(env[0])")
            }
        }
    }

    func testHexCoderDecodesFlexibleInput() {
        // HexCoder.decode 只应返回 nil（或正常 Data），不 crash。
        let inputs: [String] = [
            "", "0", "00", "01", "0g", "gg", "00AA",
            String(repeating: "ab", count: 64),
            String(repeating: "ab", count: 500),
        ]
        for s in inputs {
            _ = HexCoder.decode(s)
        }
    }

    func testWsPutRequestRoundTripStable() throws {
        let put = WsPutRequest(path: "x", offset: 0, mode: 0o644, dataHex: "aa")
        let data = try JSONEncoder().encode(put)
        let decoded = try JSONDecoder().decode(WsPutRequest.self, from: data)
        XCTAssertEqual(decoded, put)
    }
}
