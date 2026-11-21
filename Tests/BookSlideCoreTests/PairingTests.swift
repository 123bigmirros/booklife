import XCTest
import CryptoKit
@testable import BookSlideCore

final class PairingTests: XCTestCase {
    func testIPadCredentialsAndLegacyMacDecode() throws {
        let ipad = SavedConnection(receiverID: UUID(), name: "iPad", endpoint: "http://ipad.local:8765",
            token: String(repeating: "a", count: 32), deviceKind: "ipad")
        let key = SymmetricKey(size: .bits256), id = UUID()
        let encrypted = try PairingCrypto.seal(ipad, key: key, id: id)
        XCTAssertEqual(try PairingCrypto.open(encrypted, key: key, id: id), ipad)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ipad)) as? [String: Any])
        legacy.removeValue(forKey: "deviceKind")
        let decoded = try JSONDecoder().decode(SavedConnection.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.deviceKind)
        XCTAssertTrue(decoded.isValid)
    }
    private let now = Date(timeIntervalSince1970: 1000)
    private let receiverID = UUID()
    private var saved: SavedConnection {
        SavedConnection(receiverID: receiverID, name: "Test Mac", endpoint: "http://test-mac.local:8765", token: String(repeating: "a", count: 32))
    }
    private func post<T: Encodable>(_ path: String, _ value: T) throws -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v2/pair/" + path, headers: [:], body: try JSONEncoder().encode(value))
    }

    func testRequiresExplicitMacApprovalAndEncryptsCredentials() throws {
        let coordinator = PairingCoordinator(receiverID: receiverID) { self.saved }
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = PairingHello(id: UUID(), clientName: "iPhone", publicKey: clientKey.publicKey.rawRepresentation)
        let start = try post("start", hello)
        XCTAssertEqual(coordinator.handle(start, now: now)?.status, 409)
        coordinator.begin(now: now)
        let response = try XCTUnwrap(coordinator.handle(start, now: now))
        let challenge = try XCTUnwrap(response.reply.pairing)
        let key = try PairingCrypto.key(privateKey: clientKey, remote: challenge.publicKey,
            clientPublic: hello.publicKey, serverPublic: challenge.publicKey, id: hello.id, receiverID: receiverID)
        XCTAssertEqual(PairingCrypto.comparisonCode(key), coordinator.pending?.code)
        XCTAssertFalse(String(decoding: response.data, as: UTF8.self).contains(saved.token))
        let poll = try post("poll", PairingPoll(id: hello.id))
        XCTAssertEqual(coordinator.handle(poll, now: now)?.status, 202)
        XCTAssertNil(coordinator.handle(poll, now: now)?.reply.encryptedConnection)
        XCTAssertFalse(coordinator.approve(id: UUID(), now: now))
        XCTAssertTrue(coordinator.approve(id: hello.id, now: now))
        let completed = try XCTUnwrap(coordinator.handle(poll, now: now))
        let envelope = try XCTUnwrap(completed.reply.encryptedConnection)
        XCTAssertEqual(try PairingCrypto.open(envelope, key: key, id: hello.id), saved)
        XCTAssertFalse(String(decoding: completed.data, as: UTF8.self).contains(saved.token))
        XCTAssertThrowsError(try PairingCrypto.open(envelope, key: SymmetricKey(size: .bits256), id: hello.id))
        XCTAssertThrowsError(try PairingCrypto.open(envelope, key: key, id: UUID()))
        XCTAssertEqual(coordinator.handle(poll, now: now.addingTimeInterval(31))?.status, 410)
    }

    func testPendingRequestCannotBeReplacedAndExpires() throws {
        let coordinator = PairingCoordinator(receiverID: receiverID) { self.saved }
        let a = PairingHello(id: UUID(), clientName: "Phone A", publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let b = PairingHello(id: UUID(), clientName: "Phone B", publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        coordinator.begin(now: now)
        XCTAssertEqual(coordinator.handle(try post("start", a), now: now)?.status, 200)
        let originalCode = coordinator.pending?.code
        XCTAssertEqual(coordinator.handle(try post("start", a), now: now)?.status, 200)
        XCTAssertEqual(coordinator.pending?.code, originalCode)
        XCTAssertEqual(coordinator.handle(try post("start", b), now: now)?.status, 409)
        XCTAssertFalse(coordinator.approve(id: a.id, now: now.addingTimeInterval(121)))
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(coordinator.handle(try post("poll", PairingPoll(id: a.id)), now: now)?.status, 410)
    }

    func testRejectAndNewWindowInvalidateOldChallenge() throws {
        let coordinator = PairingCoordinator(receiverID: receiverID) { self.saved }
        let hello = PairingHello(id: UUID(), clientName: "iPhone", publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        coordinator.begin(now: now)
        _ = coordinator.handle(try post("start", hello), now: now)
        coordinator.clear(); coordinator.begin(now: now)
        XCTAssertFalse(coordinator.approve(id: hello.id, now: now))
        XCTAssertEqual(coordinator.handle(try post("poll", PairingPoll(id: hello.id)), now: now)?.status, 410)
    }

    func testSignedRequestRejectsBodyChangesWrongKeyAndReplayAfterExpiry() throws {
        let body = Data("next".utf8)
        let headers = RequestAuthentication.headers(method: "POST", path: "/v1/turn", body: body, token: saved.token, now: now)
        let request = HTTPRequest(method: "POST", path: "/v1/turn", headers: headers, body: body)
        XCTAssertTrue(RequestAuthentication.verify(request, token: saved.token, now: now))
        XCTAssertFalse(RequestAuthentication.verify(request, token: "wrong", now: now))
        XCTAssertFalse(RequestAuthentication.verify(request, token: saved.token, now: now.addingTimeInterval(11)))
        XCTAssertFalse(RequestAuthentication.verify(HTTPRequest(method: "POST", path: "/v1/turn", headers: headers, body: Data("previous".utf8)), token: saved.token, now: now))
        XCTAssertFalse(RequestAuthentication.verify(HTTPRequest(method: "GET", path: "/v1/status", headers: ["authorization": "Bearer " + saved.token]), token: saved.token, now: now))
        let response = RequestAuthentication.sign(HTTPResponse(200, Reply(ok: true, message: "Sent")), for: request, token: saved.token)
        XCTAssertTrue(RequestAuthentication.verifyResponse(status: 200, body: response.body, signature: response.extraHeaders["X-BookSlide-Signature"], nonce: headers["x-bookslide-nonce"]!, token: saved.token))
        XCTAssertFalse(RequestAuthentication.verifyResponse(status: 200, body: Data("spoofed".utf8), signature: response.extraHeaders["X-BookSlide-Signature"], nonce: headers["x-bookslide-nonce"]!, token: saved.token))
    }

    func testOnlyLocalConnectionAddressesAccepted() {
        XCTAssertNotNil(SavedConnection.localURL("http://MacBook.local:8765"))
        XCTAssertNotNil(SavedConnection.localURL("http://192.168.1.2:8765"))
        for url in ["http://192..168.1.2:8765", "http://evil.example:8765", "http://a:b@Mac.local:8765", "http://Mac.local:8765/path", "http://Mac.local:0"] {
            XCTAssertNil(SavedConnection.localURL(url), url)
        }
    }
}
