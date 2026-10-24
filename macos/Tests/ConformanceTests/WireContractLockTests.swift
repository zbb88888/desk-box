import XCTest
@testable import DeskBoxCore

/// M2-4a：Windows/Multiple phase 共享 wire contract 的稳定字形。
/// 任何字段名字段序破坏都会让跨平台适配错位，通过 fail 在 CI 与 Windows build 前暴露。
final class WireContractLockTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func testControlFrameWireFieldShapeStable() throws {
        let frame = try ControlFrame(
            kind: .request,
            sequence: 42,
            requestID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            payload: Data("{\"x\":1}".utf8)
        )
        let data = try frame.encoded()
        // header(36): magic(4) | version(2) | kind(2) | sequence(8) | requestID(16) | payloadLength(4)
        XCTAssertEqual(data.count, 36 + "{\"x\":1}".count)
        XCTAssertEqual(data[0], 0x44) // 'D'
        XCTAssertEqual(data[1], 0x42) // 'B'
        XCTAssertEqual(data[2], 0x58) // magic bytes 3-4 'X' '1'? 只锁前两位成体
        // kind big-endian at byte 6..7（kind = .request → raw 4）
        XCTAssertEqual(data[6], 0)
        XCTAssertEqual(data[7], 4)
        // sequence 42 big-endian at byte 15
        XCTAssertEqual(data[15], 42)
        // payload length big-endian at byte 35
        XCTAssertEqual(data[35], 7)
    }

    func testBrokerFetchJsonShapeStable() throws {
        let req = BrokerFetchRequest(reqId: 7, url: "https://example.com", savePath: "/workspace/inbound/x")
        let data = try encoder.encode(req)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json,
                       "{\"reqId\":7,\"savePath\":\"/workspace/inbound/x\",\"url\":\"https://example.com\"}")
    }

    func testWsFramesShapeStable() throws {
        let begin = WsBeginRequest(wsId: "W", fileCount: 3, totalBytes: 12)
        let beginJSON = String(decoding: try encoder.encode(begin), as: UTF8.self)
        XCTAssertEqual(beginJSON, "{\"fileCount\":3,\"totalBytes\":12,\"wsId\":\"W\"}")

        let put = WsPutRequest(path: "a.txt", offset: 0, mode: 0o644, dataHex: "6161")
        let putJSON = String(decoding: try encoder.encode(put), as: UTF8.self)
        XCTAssertEqual(putJSON, "{\"dataHex\":\"6161\",\"mode\":420,\"offset\":0,\"path\":\"a.txt\"}")

        let ack = WsAckEvent(wsId: "W", ok: true, error: nil)
        let ackJSON = String(decoding: try encoder.encode(ack), as: UTF8.self)
        XCTAssertEqual(ackJSON, "{\"ok\":true,\"wsId\":\"W\"}")
    }

    func testPtyEventShapeStable() throws {
        let opened = PtyEvent(ptyId: 0, type: .opened)
        let json = String(decoding: try encoder.encode(opened), as: UTF8.self)
        XCTAssertEqual(json, "{\"dataHex\":\"\",\"ptyId\":0,\"type\":\"opened\"}")
    }

    func testBrokerEndShapeStable() throws {
        let end = BrokerFetchEnd(reqId: 5, status: 200, ok: true, error: nil)
        let json = String(decoding: try encoder.encode(end), as: UTF8.self)
        XCTAssertEqual(json, "{\"ok\":true,\"reqId\":5,\"status\":200}")
    }

    func testControlMessageKindsStable() {
        XCTAssertEqual(ControlMessageKind.hello.rawValue, 1)
        XCTAssertEqual(ControlMessageKind.helloAck.rawValue, 2)
        XCTAssertEqual(ControlMessageKind.readiness.rawValue, 3)
        XCTAssertEqual(ControlMessageKind.request.rawValue, 4)
        XCTAssertEqual(ControlMessageKind.response.rawValue, 5)
        XCTAssertEqual(ControlMessageKind.event.rawValue, 6)
        XCTAssertEqual(ControlMessageKind.close.rawValue, 7)
        XCTAssertEqual(ControlMessageKind.keyExchange.rawValue, 8)
        XCTAssertEqual(ControlMessageKind.ptyOpen.rawValue, 9)
        XCTAssertEqual(ControlMessageKind.ptyInput.rawValue, 10)
        XCTAssertEqual(ControlMessageKind.ptyResize.rawValue, 11)
        XCTAssertEqual(ControlMessageKind.ptyClose.rawValue, 12)
        XCTAssertEqual(ControlMessageKind.ptyEvent.rawValue, 13)
        XCTAssertEqual(ControlMessageKind.wsBegin.rawValue, 14)
        XCTAssertEqual(ControlMessageKind.wsPut.rawValue, 15)
        XCTAssertEqual(ControlMessageKind.wsEnd.rawValue, 16)
        XCTAssertEqual(ControlMessageKind.wsAck.rawValue, 17)
        XCTAssertEqual(ControlMessageKind.brokerFetch.rawValue, 21)
        XCTAssertEqual(ControlMessageKind.brokerData.rawValue, 22)
        XCTAssertEqual(ControlMessageKind.brokerEnd.rawValue, 23)
    }
}
