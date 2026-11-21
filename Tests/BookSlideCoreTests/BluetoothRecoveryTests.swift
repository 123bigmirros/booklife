import XCTest
@testable import BookSlideCore

final class BluetoothRecoveryTests: XCTestCase {
    func testOneSlowReplyDoesNotRequireTransportReset() {
        var exchange = BluetoothExchangeLifecycle()
        let id = UUID()
        XCTAssertTrue(exchange.begin(id: id, now: 0, active: true))
        XCTAssertNil(exchange.timeout(now: 4.9))
        XCTAssertEqual(exchange.timeout(now: 5), .replyDelayed)
        XCTAssertTrue(exchange.callerFinished)
        XCTAssertEqual(exchange.id, id, "Keep draining the same response on the existing BLE connection")
        XCTAssertNil(exchange.timeout(now: 6))
        XCTAssertFalse(exchange.begin(id: UUID(), now: 6, active: true), "No second turn while an acknowledgement is uncertain")
        XCTAssertTrue(exchange.complete(id: id))
        XCTAssertNil(exchange.nextTimeout(after: 30))
        XCTAssertTrue(exchange.begin(id: UUID(), now: 31, active: true))
    }
    func testOnlySustainedForegroundStallRequiresReset() {
        var exchange = BluetoothExchangeLifecycle()
        XCTAssertTrue(exchange.begin(id: UUID(), now: 100, active: true))
        XCTAssertEqual(exchange.timeout(now: 105), .replyDelayed)
        XCTAssertNil(exchange.timeout(now: 114.9))
        XCTAssertEqual(exchange.timeout(now: 115), .transportStalled)
    }
    func testWatchSuspensionDoesNotSpendTimeoutBudget() {
        var exchange = BluetoothExchangeLifecycle()
        let id = UUID()
        XCTAssertTrue(exchange.begin(id: id, now: 0, active: true))
        exchange.setActive(false, now: 1)
        XCTAssertTrue(exchange.abandonCaller(), "Do not play a delayed success haptic after wake")
        XCTAssertFalse(exchange.abandonCaller())
        XCTAssertNil(exchange.timeout(now: 3600))
        XCTAssertNil(exchange.nextTimeout(after: 3600))
        exchange.setActive(true, now: 3601)
        XCTAssertEqual(exchange.nextTimeout(after: 3601), 14)
        XCTAssertNil(exchange.timeout(now: 3602))
        XCTAssertTrue(exchange.complete(id: id))
    }
    func testOldAcknowledgementCannotReleaseNewRequest() {
        var exchange = BluetoothExchangeLifecycle()
        let old = UUID(), new = UUID()
        XCTAssertTrue(exchange.begin(id: old, now: 0, active: true))
        XCTAssertEqual(exchange.timeout(now: 5), .replyDelayed)
        XCTAssertTrue(exchange.complete(id: old))
        XCTAssertTrue(exchange.begin(id: new, now: 6, active: true))
        XCTAssertFalse(exchange.complete(id: old))
        XCTAssertEqual(exchange.id, new)
        XCTAssertFalse(exchange.callerFinished)
    }
    func testSuccessfulReplyCancelsBothTimeoutStages() {
        var exchange = BluetoothExchangeLifecycle()
        let id = UUID()
        XCTAssertTrue(exchange.begin(id: id, now: 0, active: true))
        XCTAssertTrue(exchange.complete(id: id))
        XCTAssertNil(exchange.timeout(now: 5))
        XCTAssertNil(exchange.timeout(now: 15))
    }
    func testForegroundTransitionsAccumulateOnlyActiveTime() {
        var exchange = BluetoothExchangeLifecycle()
        XCTAssertTrue(exchange.begin(id: UUID(), now: 0, active: true))
        exchange.setActive(false, now: 2)
        exchange.setActive(true, now: 100)
        exchange.setActive(false, now: 101)
        exchange.setActive(true, now: 1000)
        XCTAssertNil(exchange.timeout(now: 1001))
        XCTAssertEqual(exchange.timeout(now: 1002), .replyDelayed)
    }
}
