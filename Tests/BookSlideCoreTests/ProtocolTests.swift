import XCTest
@testable import BookSlideCore

final class ProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let token = "test-pairing-token"

    private func request(_ command: TurnCommand, token: String? = nil) throws -> HTTPRequest {
        let body = try JSONEncoder().encode(command)
        var headers = RequestAuthentication.headers(method: "POST", path: "/v1/turn", body: body, token: token ?? self.token, now: now)
        headers["content-type"] = "application/json"
        return HTTPRequest(method: "POST", path: "/v1/turn", headers: headers, body: body)
    }

    func testFragmentedRequestAndUTF8ResponseLength() throws {
        let body = Data("{\"text\":\"下一页\"}".utf8)
        var bytes = Data("POST /v1/turn HTTP/1.1\r\nHost: mac.local\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        bytes.append(body)
        var parser = HTTPParser()
        for byte in bytes.dropLast() { XCTAssertNil(try parser.append(Data([byte]))) }
        let parsed = try XCTUnwrap(parser.append(Data([bytes.last!])))
        XCTAssertEqual(parsed.body, body)
        let response = HTTPResponse(200, Reply(ok: true, message: "已发送翻页按键")).data
        let split = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.contains("Content-Length: \(response.count - split.upperBound)\r\n"))
    }

    func testRejectsAmbiguousAndOversizedHTTP() {
        for header in [
            "Content-Length: 0\r\nContent-Length: 1\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Content-Length: -1\r\n",
            "Content-Length: 9000\r\n"
        ] {
            var parser = HTTPParser()
            XCTAssertThrowsError(try parser.append(Data("POST /v1/turn HTTP/1.1\r\nHost: mac\r\n\(header)\r\n".utf8)))
        }
        var parser = HTTPParser()
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: 8193)))
    }

    func testUnauthorizedExpiredAndUnreadyNeverExecute() throws {
        var executions = 0
        var problem: String?
        let router = CommandRouter(token: token, readiness: { problem }, execute: { _ in executions += 1; return nil })
        let valid = TurnCommand(direction: .next, sentAt: now.timeIntervalSince1970)
        XCTAssertEqual(router.handle(try request(valid, token: "wrong"), now: now).status, 401)
        XCTAssertEqual(router.handle(try request(TurnCommand(direction: .next, sentAt: 980)), now: now).status, 408)
        XCTAssertEqual(router.handle(try request(TurnCommand(direction: .next, sentAt: 1020)), now: now).status, 408)
        problem = "Books is not foreground"
        XCTAssertEqual(router.handle(try request(valid), now: now).status, 409)
        XCTAssertEqual(executions, 0)
    }

    func testDuplicateIDIsAtMostOnceAndDirectionCannotChange() throws {
        var directions: [PageDirection] = []
        let router = CommandRouter(token: token, readiness: { nil }, execute: { directions.append($0); return nil })
        let command = TurnCommand(direction: .next, sentAt: now.timeIntervalSince1970)
        let first = router.handle(try request(command), now: now)
        let duplicate = router.handle(try request(command), now: now.addingTimeInterval(1))
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.reply, duplicate.reply)
        let collision = TurnCommand(id: command.id, direction: .previous, sentAt: now.timeIntervalSince1970)
        XCTAssertEqual(router.handle(try request(collision), now: now).status, 409)
        XCTAssertEqual(directions, [.next])
    }

    func testRapidGestureDoesNotDoubleTurnButPreviousWorksAfterCooldown() throws {
        var directions: [PageDirection] = []
        let router = CommandRouter(token: token, readiness: { nil }, execute: { directions.append($0); return nil })
        XCTAssertEqual(router.handle(try request(TurnCommand(direction: .next, sentAt: 1000)), now: now).status, 200)
        XCTAssertEqual(router.handle(try request(TurnCommand(direction: .next, sentAt: 1000)), now: now.addingTimeInterval(0.1)).status, 429)
        XCTAssertEqual(router.handle(try request(TurnCommand(direction: .previous, sentAt: 1001)), now: now.addingTimeInterval(1)).status, 200)
        XCTAssertEqual(directions, [.next, .previous])
    }

    func testStatusDoesNotTurnPageAndExecutionFailureIsReported() throws {
        var executions = 0
        let router = CommandRouter(token: token, readiness: { nil }, execute: { _ in executions += 1; return "Key event failed" })
        let status = HTTPRequest(method: "GET", path: "/v1/status", headers: RequestAuthentication.headers(method: "GET", path: "/v1/status", token: token, now: now))
        XCTAssertTrue(router.handle(status, now: now).reply.ok)
        XCTAssertEqual(executions, 0)
        let response = router.handle(try request(TurnCommand(direction: .previous, sentAt: 1000)), now: now)
        XCTAssertEqual(response.status, 503)
        XCTAssertFalse(response.reply.ok)
    }

    func testRelayAcknowledgementIsTruthfulAndDuplicateIsNotRedispatched() throws {
        var executions = 0
        let router = CommandRouter(token: token, readiness: { nil }, execute: { _ in executions += 1; return nil })
        router.successMessage = { "Mac 已接受指令" }
        let command = TurnCommand(direction: .next, sentAt: now.timeIntervalSince1970)
        let first = router.handle(try request(command), now: now)
        XCTAssertEqual(first.reply.message, "Mac 已接受指令")
        router.successMessage = { "已发送翻页按键" }
        XCTAssertEqual(router.handle(try request(command), now: now.addingTimeInterval(1)).reply, first.reply)
        XCTAssertEqual(executions, 1)
    }
}
