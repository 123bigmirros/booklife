import XCTest
@testable import BookSlideCore

final class BluetoothWireTests: XCTestCase {
    func testFragmentationAtSmallATTMTUAndDecoderReuse() throws {
        let payload = Data(repeating: 0xA5, count: 1300)
        var decoder = BluetoothFrameDecoder()
        for _ in 0..<2 {
            let chunks = try BluetoothWire.frame(payload, mtu: 20)
            for chunk in chunks.dropLast() { XCTAssertNil(try decoder.append(chunk)) }
            XCTAssertEqual(try decoder.append(chunks.last!), payload)
        }
    }
    func testRejectsOversizedAndTrailingFrames() throws {
        var decoder = BluetoothFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 1, 0, 0])))
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 1, 7, 8])))
        XCTAssertEqual(try decoder.append(Data([0, 0, 0, 1, 9])), Data([9]))
        XCTAssertThrowsError(try BluetoothWire.frame(Data(repeating: 0, count: 16385), mtu: 20))
    }
    func testSplitLengthHeader() throws {
        var decoder = BluetoothFrameDecoder()
        for byte: UInt8 in [0, 0, 0, 2, 8] { XCTAssertNil(try decoder.append(Data([byte]))) }
        XCTAssertEqual(try decoder.append(Data([9])), Data([8, 9]))
    }
    func testIPadFractionalScrollOverBLERejectsBackgroundAndOldSessions() async throws {
        let token = String(repeating: "b", count: 32), book = UUID()
        var session = UUID(), foreground = true, offset = 0.0, calls = 0
        let router = ReadingRouter(token: token, snapshot: {
            var snapshot = ReadingSnapshot(sessionID: session, bookID: book, title: "iPad",
                page: 1, pageCount: 50, readingMode: .scroll, viewportOffset: offset)
            snapshot.supportsFractionalScroll = true; snapshot.maxScrollLines = 16
            return snapshot
        }, readiness: { foreground ? nil : "iPad 已进入后台" },
        turn: { _ in XCTFail("Crown input must stay fractional"); return nil },
        scroll: { direction, lines in
            offset += lines * (direction == .next ? 1 : -1); calls += 1; return nil
        })
        func transport<T: Codable>(_ value: T) throws -> T {
            var decoder = BluetoothFrameDecoder(), bytes: Data?
            for fragment in try BluetoothWire.frame(JSONEncoder().encode(value), mtu: 20) {
                if let result = try decoder.append(fragment) { bytes = result }
            }
            return try JSONDecoder().decode(T.self, from: XCTUnwrap(bytes))
        }
        func send(_ command: TurnCommand) async throws -> Reply {
            let body = try JSONEncoder().encode(command)
            var headers = RequestAuthentication.headers(method: "POST", path: "/v3/turn", body: body, token: token)
            headers["content-type"] = "application/json"
            let packet = try transport(BluetoothRequest(HTTPRequest(method: "POST", path: "/v3/turn", headers: headers, body: body)))
            let response = try transport(BluetoothResponse(id: packet.id, response: await router.handle(packet.request)))
            XCTAssertTrue(RequestAuthentication.verifyResponse(status: response.status, body: response.body,
                signature: response.signature, nonce: headers["x-bookslide-nonce"]!, token: token))
            return try JSONDecoder().decode(Reply.self, from: response.body)
        }
        let forward = TurnCommand(direction: .next, sessionID: session, scrollLines: 12.0625)
        let first = try await send(forward)
        XCTAssertTrue(first.ok); XCTAssertEqual(offset, 12.0625)
        let duplicate = try await send(forward)
        XCTAssertTrue(duplicate.ok); XCTAssertEqual(calls, 1)
        let reverse = try await send(TurnCommand(direction: .previous, sessionID: session, scrollLines: 0.0625))
        XCTAssertTrue(reverse.ok); XCTAssertEqual(offset, 12)
        foreground = false
        let blocked = try await send(TurnCommand(direction: .next, sessionID: session, scrollLines: 1))
        XCTAssertFalse(blocked.ok); XCTAssertEqual(calls, 2)
        let stale = TurnCommand(direction: .next, sessionID: session, scrollLines: 1)
        session = UUID(); foreground = true
        let restored = try await send(stale)
        XCTAssertFalse(restored.ok); XCTAssertEqual(calls, 2)
    }
    func testSignedCommandAndAcknowledgementSurviveBLETransport() async throws {
        let token = String(repeating: "a", count: 32)
        let session = UUID(), book = UUID()
        var page = 1, turns = 0
        let router = ReadingRouter(token: token, snapshot: {
            ReadingSnapshot(sessionID: session, bookID: book, title: "蓝牙测试", page: page, pageCount: 10)
        }, readiness: { nil }, turn: { _ in page += 1; turns += 1; return nil })
        let command = TurnCommand(direction: .next, sessionID: session)
        let body = try JSONEncoder().encode(command)
        var headers = RequestAuthentication.headers(method: "POST", path: "/v3/turn", body: body, token: token)
        headers["content-type"] = "application/json"
        let request = BluetoothRequest(HTTPRequest(method: "POST", path: "/v3/turn", headers: headers, body: body))
        func roundTrip<T: Codable>(_ value: T) throws -> T {
            var decoder = BluetoothFrameDecoder()
            var result: Data?
            for fragment in try BluetoothWire.frame(JSONEncoder().encode(value), mtu: 20) {
                if let data = try decoder.append(fragment) { result = data }
            }
            return try JSONDecoder().decode(T.self, from: XCTUnwrap(result))
        }
        let received = try roundTrip(request)
        XCTAssertTrue(BluetoothWire.allows(received.request))
        for _ in 0..<2 {
            let response = try roundTrip(BluetoothResponse(id: received.id, response: await router.handle(received.request)))
            XCTAssertEqual(response.id, request.id)
            XCTAssertTrue(RequestAuthentication.verifyResponse(status: response.status, body: response.body, signature: response.signature,
                                                               nonce: headers["x-bookslide-nonce"]!, token: token))
            let reply = try JSONDecoder().decode(Reply.self, from: response.body)
            XCTAssertTrue(reply.ok); XCTAssertEqual(reply.commandID, command.id); XCTAssertEqual(reply.reading?.page, 2)
        }
        XCTAssertEqual(turns, 1, "Duplicate BLE commands must not turn a second page")
        XCTAssertFalse(BluetoothWire.allows(HTTPRequest(method: "GET", path: "/v3/library", headers: [:])))
    }
}
