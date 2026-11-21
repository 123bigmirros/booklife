import XCTest
import Foundation
import CryptoKit
import BookSlideCore
@testable import BookSlideTransport

final class HTTPServerTests: XCTestCase {
    @MainActor
    func testWatchFineScrollReachesLANReaderAndRejectsSuspendedSession() async throws {
        let token = "ipad-test-token", receiverID = UUID(), bookID = UUID()
        var readingSession = UUID(), offset = 0.0, foreground = true
        var movements: [Double] = []
        func snapshot() -> ReadingSnapshot {
            var value = ReadingSnapshot(sessionID: readingSession, bookID: bookID, title: "iPad EPUB",
                page: 1, pageCount: 10, locator: "same-image", canGoNext: true,
                canGoPrevious: offset > 0, readingMode: .scroll, viewportOffset: offset)
            value.supportsFractionalScroll = true
            return value
        }
        let router = ReadingRouter(token: token, snapshot: { snapshot() },
            readiness: { foreground ? nil : "iPad is backgrounded" },
            turn: { _ in XCTFail("Crown movement must retain its line count"); return nil },
            scroll: { direction, lines in
                let delta = (direction == .next ? 1 : -1) * lines
                movements.append(delta); offset += Double(delta * 30); return nil
            })
        let server = HTTPServer { await router.handle($0) }
        let ready = expectation(description: "iPad receiver listening")
        var port: UInt16?
        server.onState = { _, value in if let value { port = value; ready.fulfill() } }
        try server.start(port: 0, loopbackOnly: true, deviceKind: "ipad")
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let actualPort = try XCTUnwrap(port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let state = PhoneControlState(receiverID: receiverID, receiverName: "iPad", controlID: UUID(), reading: snapshot())
        func forward(_ direction: PageDirection, _ lines: Double, id: UUID = UUID()) async throws -> Reply {
            let watch = WatchTurnRequest(controlID: state.controlID!, receiverID: receiverID,
                command: TurnCommand(id: id, direction: direction, sessionID: state.reading!.sessionID, scrollLines: lines))
            let decoded = try JSONDecoder().decode(WatchTurnRequest.self, from: JSONEncoder().encode(watch))
            XCTAssertTrue(state.accepts(decoded))
            let body = try JSONEncoder().encode(decoded.command)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(actualPort)/v3/turn")!)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let headers = RequestAuthentication.headers(method: "POST", path: "/v3/turn", body: body, token: token)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertTrue(RequestAuthentication.verifyResponse(status: http.statusCode, body: data,
                signature: http.value(forHTTPHeaderField: "X-BookSlide-Signature"), nonce: headers["x-bookslide-nonce"]!, token: token))
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            XCTAssertEqual(reply.commandID, decoded.command.id)
            return reply
        }
        let down = try await forward(.next, 4)
        XCTAssertTrue(down.ok); XCTAssertEqual(down.reading?.viewportOffset, 120)
        let up = try await forward(.previous, 1)
        XCTAssertTrue(up.ok); XCTAssertEqual(up.reading?.viewportOffset, 90)
        let fractional = try await forward(.next, 1.0/16)
        XCTAssertTrue(fractional.ok); XCTAssertEqual(fractional.reading?.viewportOffset,91.875)
        XCTAssertEqual(fractional.reading?.supportsFractionalScroll,true)
        foreground = false
        let background = try await forward(.next, 1)
        XCTAssertFalse(background.ok)
        readingSession = UUID(); foreground = true
        let stale = try await forward(.next, 1)
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(movements, [4, -1, 1.0/16])
    }
    @MainActor
    func testBonjourDiscoveryAndEncryptedPairingOverHTTP() async throws {
        let id = UUID()
        let expected = SavedConnection(receiverID: id, name: "Test Mac", endpoint: "http://test-mac.local:8765", token: String(repeating: "b", count: 32))
        let coordinator = PairingCoordinator(receiverID: id) { expected }
        coordinator.begin()
        let server = HTTPServer { coordinator.handle($0) ?? HTTPResponse(404, Reply(ok: false, message: "unknown")) }
        let ready = expectation(description: "Pairing server ready")
        let discovered = expectation(description: "Bonjour service discovered and resolved")
        var port: UInt16?
        server.onState = { _, value in if let value { port = value; ready.fulfill() } }
        let probe = DiscoveryProbe(expectedID: id) { discovered.fulfill() }
        probe.start()
        try server.start(port: 0, loopbackOnly: true, serviceName: "BookSlide-Test-" + id.uuidString, receiverID: id)
        defer { probe.stop(); server.stop() }
        await fulfillment(of: [ready, discovered], timeout: 10)
        let actualPort = try XCTUnwrap(port)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func post<T: Encodable>(_ path: String, _ payload: T) async throws -> (Reply, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(actualPort)/v2/pair/\(path)")!)
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await session.data(for: request)
            return (try JSONDecoder().decode(Reply.self, from: data), data)
        }
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = PairingHello(id: UUID(), clientName: "Test iPhone", publicKey: clientKey.publicKey.rawRepresentation)
        let (start, _) = try await post("start", hello)
        let challenge = try XCTUnwrap(start.pairing)
        let key = try PairingCrypto.key(privateKey: clientKey, remote: challenge.publicKey, clientPublic: hello.publicKey, serverPublic: challenge.publicKey, id: hello.id, receiverID: id)
        XCTAssertEqual(PairingCrypto.comparisonCode(key), coordinator.pending?.code)
        let (pending, _) = try await post("poll", PairingPoll(id: hello.id))
        XCTAssertNil(pending.encryptedConnection)
        XCTAssertTrue(coordinator.approve(id: hello.id))
        let (reply, wireBytes) = try await post("poll", PairingPoll(id: hello.id))
        let decrypted = try PairingCrypto.open(XCTUnwrap(reply.encryptedConnection), key: key, id: hello.id)
        XCTAssertEqual(decrypted, expected)
        XCTAssertFalse(String(decoding: wireBytes, as: UTF8.self).contains(expected.token))
    }

    @MainActor
    func testRealHTTPAuthenticationDeliveryAndDuplicateSuppression() async throws {
        var directions: [PageDirection] = []
        let token = "integration-test-token"
        let router = CommandRouter(token: token, readiness: { nil }, execute: { directions.append($0); return nil })
        let server = HTTPServer { router.handle($0) }
        let ready = expectation(description: "Server listening")
        var actualPort: UInt16?
        server.onState = { _, port in if let port { actualPort = port; ready.fulfill() } }
        try server.start(port: 0, loopbackOnly: true)
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(actualPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let command = TurnCommand(direction: .next)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/turn")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(command)
        let (_, rejected) = try await session.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(directions.isEmpty)
        let headers = RequestAuthentication.headers(method: "POST", path: "/v1/turn", body: request.httpBody!, token: token)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        for _ in 0..<2 {
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(RequestAuthentication.verifyResponse(status: 200, body: data,
                signature: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-BookSlide-Signature"),
                nonce: headers["x-bookslide-nonce"]!, token: token))
            XCTAssertEqual(try JSONDecoder().decode(Reply.self, from: data).commandID, command.id)
        }
        XCTAssertEqual(directions, [.next])
    }
    @MainActor
    func testAsyncReaderHTTPReturnsActualLocationAndRejectsOldBook() async throws {
        let token = "reader-http-test-token"
        let sessionID = UUID(), bookID = UUID()
        var reading = ReadingSnapshot(sessionID:sessionID,bookID:bookID,title:"EPUB",page:1,pageCount:4,locator:"cfi-1")
        var turns = 0
        let router = ReadingRouter(token:token,snapshot:{reading},readiness:{nil},turn:{_ in
            try? await Task.sleep(nanoseconds:30_000_000)
            turns += 1
            reading = ReadingSnapshot(sessionID:sessionID,bookID:bookID,title:"EPUB",page:2,pageCount:4,locator:"cfi-2")
            return nil
        })
        let server = HTTPServer { await router.handle($0) }
        let ready = expectation(description:"Reader listening")
        var port: UInt16?
        server.onState = { _,value in if let value { port = value; ready.fulfill() } }
        try server.start(port:0,loopbackOnly:true)
        defer { server.stop() }
        await fulfillment(of:[ready],timeout:5)
        let actualPort = try XCTUnwrap(port)
        let session = URLSession(configuration:.ephemeral)
        defer { session.invalidateAndCancel() }
        func send(_ command: TurnCommand) async throws -> Reply {
            let body = try JSONEncoder().encode(command)
            var request = URLRequest(url:URL(string:"http://127.0.0.1:\(actualPort)/v3/turn")!)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            let headers = RequestAuthentication.headers(method:"POST",path:"/v3/turn",body:body,token:token)
            headers.forEach { request.setValue($0.value,forHTTPHeaderField:$0.key) }
            let (data,response) = try await session.data(for:request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertTrue(RequestAuthentication.verifyResponse(status:http.statusCode,body:data,signature:http.value(forHTTPHeaderField:"X-BookSlide-Signature"),nonce:headers["x-bookslide-nonce"]!,token:token))
            return try JSONDecoder().decode(Reply.self,from:data)
        }
        let command = TurnCommand(direction:.next,sessionID:sessionID)
        let first = try await send(command)
        XCTAssertEqual(first.reading?.locator,"cfi-2")
        XCTAssertTrue(first.ok)
        let repeated = try await send(command)
        XCTAssertEqual(repeated,first); XCTAssertEqual(turns,1)
        reading = ReadingSnapshot(sessionID:UUID(),bookID:UUID(),title:"Other book",page:1,pageCount:4,locator:"new-cfi")
        let stale = try await send(TurnCommand(direction:.next,sessionID:sessionID))
        XCTAssertFalse(stale.ok); XCTAssertEqual(turns,1)
    }

}

private final class DiscoveryProbe: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    let expectedID: UUID
    let found: () -> Void
    let browser = NetServiceBrowser()
    var services: [NetService] = []
    var completed = false
    init(expectedID: UUID, found: @escaping () -> Void) { self.expectedID = expectedID; self.found = found; super.init(); browser.delegate = self }
    func start() { browser.searchForServices(ofType: "_bookslide._tcp.", inDomain: "local.") }
    func stop() { browser.stop(); services.forEach { $0.stop() } }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        guard !completed, let txt = service.txtRecordData(),
              NetService.dictionary(fromTXTRecord: txt)["id"] == Data(expectedID.uuidString.utf8),
              service.hostName != nil, service.port > 0 else { return }
        completed = true; found()
    }
}
