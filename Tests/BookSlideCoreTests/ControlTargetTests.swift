import XCTest
@testable import BookSlideCore

final class ControlTargetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testOnlyKnownFreshTargetSelectionsAreAccepted() throws {
        let target = ReadingTarget(id: UUID(), name: "书房 iPad", kind: "ipad")
        let request = WatchTargetRequest(targetID: target.id, sentAt: 1000)
        let decoded = try JSONDecoder().decode(WatchTargetRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, request.id)
        XCTAssertTrue(decoded.isValid(targets: [target], now: now))
        XCTAssertFalse(decoded.isValid(targets: [], now: now))
        XCTAssertFalse(decoded.isValid(targets: [target], now: now.addingTimeInterval(11)))
        XCTAssertFalse(WatchTargetRequest(targetID: target.id, sentAt: 1011).isValid(targets: [target], now: now))
        XCTAssertFalse(WatchTargetRequest(targetID: target.id, sentAt: .nan).isValid(targets: [target], now: now))
    }

    func testSwitchClearsOldBookAndRejectsPreviouslyIssuedTurn() {
        let mac = ReadingTarget(id: UUID(), name: "Mac", kind: "mac")
        let ipad = ReadingTarget(id: UUID(), name: "iPad", kind: "ipad")
        let reading = ReadingSnapshot(sessionID: UUID(), bookID: UUID(), title: "Mac 的书", page: 1, pageCount: 5)
        var state = PhoneControlState(receiverID: mac.id, receiverName: mac.name, controlID: UUID(), reading: reading)
        state.targets = [mac, ipad]
        let old = WatchTurnRequest(controlID: state.controlID!, receiverID: mac.id,
            command: TurnCommand(direction: .next, sentAt: 1000, sessionID: reading.sessionID))
        XCTAssertTrue(state.accepts(old, now: now))
        state.selectTarget(ipad)
        XCTAssertEqual(state.receiverID, ipad.id)
        XCTAssertEqual(state.receiverName, ipad.name)
        XCTAssertEqual(state.receiverKind, "ipad")
        XCTAssertNil(state.reading)
        XCTAssertNil(state.controlID)
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.accepts(old, now: now))
        XCTAssertEqual(state.targets, [mac, ipad])
        state.selectTarget(mac)
        XCTAssertFalse(state.accepts(old, now: now), "Switching back must create a new control session")
    }

    func testWatchTargetCatalogContainsNoCredentialsOrAddresses() throws {
        var state = PhoneControlState(receiverID: UUID(), receiverName: "iPad", receiverKind: "ipad")
        state.targets = [ReadingTarget(id: state.receiverID!, name: "iPad", kind: "ipad")]
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(object["targets"] as? [[String: Any]])
        XCTAssertEqual(Set(targets[0].keys), ["id", "name", "kind"])
        XCTAssertNil(object["token"]); XCTAssertNil(object["endpoint"])
        XCTAssertEqual(try JSONDecoder().decode(PhoneControlState.self, from: data), state)
    }

    func testLegacyWatchStateStillDecodesWithoutCatalog() throws {
        let state = PhoneControlState(receiverName: "Mac")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "targets"); object.removeValue(forKey: "receiverKind")
        let decoded = try JSONDecoder().decode(PhoneControlState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.targets); XCTAssertNil(decoded.receiverKind)
        XCTAssertEqual(decoded.receiverName, "Mac")
    }
}
