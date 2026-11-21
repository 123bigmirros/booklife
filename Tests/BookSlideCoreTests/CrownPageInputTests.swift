import XCTest
@testable import BookSlideCore

final class CrownPageInputTests: XCTestCase {
    func testContinuousCrownPreservesGainWithSixteenSamplesPerLine() {
        var input = ContinuousCrownInput(), total = 0.0
        for _ in 0..<16 { total += input.rotate(by:1.0/64,enabled:true) ?? 0 }
        XCTAssertEqual(total,1,accuracy:0.000001)
        XCTAssertEqual(input.rotate(by:-1.0/64,enabled:true),-1.0/16)
        XCTAssertNil(input.rotate(by:1,enabled:false))
        XCTAssertNil(input.rotate(by:.nan,enabled:true))
        XCTAssertNil(input.rotate(by:0.001,enabled:true))
        input.endRotation()
        XCTAssertEqual(input.rotate(by:100,enabled:true),4)
    }
    func testTerminalAppliesReceivedDistanceImmediatelyAndKeepsFractions() {
        var motion = TerminalScrollMotion()
        for i in 0..<3 { motion.append(0.25,now:Double(i)*0.02); XCTAssertNil(motion.step(now:Double(i)*0.02)) }
        motion.append(0.25,now:0.06); XCTAssertEqual(motion.step(now:0.06),1)
        motion.reset(); motion.append(4,now:1)
        XCTAssertEqual(motion.step(now:1),4)
        XCTAssertNil(motion.step(now:1.001))
        XCTAssertNil(motion.step(now:1.02))
        XCTAssertNil(motion.step(now:1.2))
        XCTAssertEqual(motion.pending,0)
    }
    func testTerminalReversesImmediatelyAndNeverReplaysStaleMotion() {
        var motion = TerminalScrollMotion()
        motion.append(4,now:1); XCTAssertEqual(motion.step(now:1),4)
        motion.append(-1,now:1.001); XCTAssertEqual(motion.step(now:1.001),-1)
        motion.append(4,now:2); XCTAssertNil(motion.step(now:2.2)); XCTAssertEqual(motion.pending,0)
        motion.append(4,now:3); motion.reset(); XCTAssertNil(motion.step(now:3.01))
    }
    func testLiveMotionCoalescesWhileAwaitingReplyWithoutBuildingBacklog() {
        var motion = LiveScrollMotion()
        motion.append(1, now: 0)
        XCTAssertEqual(motion.take(now: 0), 1) // First command leaves immediately.
        for time in [0.03, 0.06, 0.09] { motion.append(1, now: time) }
        XCTAssertEqual(motion.take(now: 0.12), 3) // One combined command, not lost input.
        XCTAssertNil(motion.take(now: 0.13))
        for i in 1...100 { motion.append(4, now: Double(i)/100) }
        XCTAssertEqual(motion.take(now: 1.01), 4) // A slow link cannot accumulate screens.
        XCTAssertNil(motion.take(now: 1.02))
    }
    func testFailureOrChangedSessionDiscardsPendingMotion() {
        var motion = LiveScrollMotion()
        motion.append(4, now: 1)
        motion.reset() // Called for failure, mode/target/session and scene changes.
        XCTAssertNil(motion.take(now: 1.05))
        motion.append(3, now: 2)
        XCTAssertNil(motion.take(now: 2.3)) // Delayed ACK never replays an old gesture.
        motion.append(1, now: 3)
        XCTAssertEqual(motion.take(now: 3), 1)
    }
    func testReverseReplacesPendingForwardMotionAndOldSamplesExpire() {
        var motion = LiveScrollMotion()
        motion.append(3, now: 1)
        motion.append(-1, now: 1.02)
        XCTAssertEqual(motion.take(now: 1.03), -1)
        motion.append(4, now: 2)
        motion.append(1, now: 2.3)
        XCTAssertEqual(motion.take(now: 2.31), 1)
        motion.append(Double(Int.min), now: 3)
        XCTAssertEqual(motion.take(now: 3), -4)
        motion.append(1, now: .nan)
        XCTAssertNil(motion.take(now: 4))
    }
    func testFastCrownAndCoalescedPacketsRetainDistanceWithNegotiatedLimit() {
        var input = ContinuousCrownInput(), motion = LiveScrollMotion()
        XCTAssertEqual(input.rotate(by:2,enabled:true,maximumLines:16),8)
        for i in 0..<6 { motion.append(2,now:Double(i)*0.01,maximumLines:16) }
        XCTAssertEqual(motion.take(now:0.08),12)
        motion.append(1000,now:1,maximumLines:16)
        XCTAssertEqual(motion.take(now:1.01),16)
        motion.append(12,now:2,maximumLines:16)
        motion.append(-2,now:2.01,maximumLines:16)
        XCTAssertEqual(motion.take(now:2.02),-2)
        var terminal = TerminalScrollMotion()
        terminal.append(12.5,now:0)
        XCTAssertEqual(terminal.step(now:0),12)
        terminal.append(0.5,now:0.01)
        XCTAssertEqual(terminal.step(now:0.01),1)
        XCTAssertNil(terminal.step(now:0.1))
        terminal.append(0.5,now:0.11)
        terminal.append(16,now:0.12)
        XCTAssertEqual(terminal.step(now:0.12),16)
        XCTAssertEqual(terminal.pending,0.5)
    }
    func testFineScrollUsesDistanceAndRejectsInactiveMotion() {
        var input = CrownScrollInput()
        XCTAssertNil(input.rotate(by:0.1,enabled:true))
        XCTAssertEqual(input.rotate(by:0.2,enabled:true),1)
        XCTAssertEqual(input.rotate(by:0.5,enabled:true),2)
        XCTAssertEqual(input.rotate(by:100,enabled:true),4)
        XCTAssertEqual(input.rotate(by:-0.3,enabled:true),-1)
        XCTAssertNil(input.rotate(by:100,enabled:false))
        XCTAssertNil(input.rotate(by:0.1,enabled:true))
        input.endRotation()
        XCTAssertNil(input.rotate(by:0.2,enabled:true))
        XCTAssertNil(input.rotate(by:.nan,enabled:true))
        XCTAssertNil(input.rotate(by:.infinity,enabled:true))
    }
    func testFastSpinOnlyTurnsOnePageUntilIdle() {
        var input = CrownPageInput()
        XCTAssertNil(input.rotate(by:0.2,enabled:true))
        XCTAssertEqual(input.rotate(by:0.4,enabled:true), .next)
        XCTAssertNil(input.rotate(by:20,enabled:true))
        XCTAssertNil(input.rotate(by:-20,enabled:true))
        input.endRotation()
        XCTAssertEqual(input.rotate(by:-0.6,enabled:true), .previous)
    }

    func testBusyAndInactiveMotionIsNotReplayed() {
        var input = CrownPageInput()
        XCTAssertNil(input.rotate(by:5,enabled:false))
        XCTAssertNil(input.rotate(by:0.8,enabled:true))
        input.endRotation()
        XCTAssertNil(input.rotate(by:0.1,enabled:true))
        XCTAssertEqual(input.rotate(by:0.5,enabled:true), .next)
    }

    func testScrollingContinuesWithoutIdleAndCanReverse() {
        var input = CrownPageInput()
        XCTAssertEqual(input.rotate(by:0.6,enabled:true,mode:.scroll), .next)
        XCTAssertEqual(input.rotate(by:0.6,enabled:true,mode:.scroll), .next)
        XCTAssertEqual(input.rotate(by:-0.6,enabled:true,mode:.scroll), .previous)
        // Motion during a request is dropped, without latching until idle.
        XCTAssertNil(input.rotate(by:20,enabled:false,mode:.scroll))
        XCTAssertNil(input.rotate(by:0.1,enabled:true,mode:.scroll))
        XCTAssertEqual(input.rotate(by:0.5,enabled:true,mode:.scroll), .next)
        input.endRotation()
        XCTAssertNil(input.rotate(by:0.1,enabled:true,mode:.scroll))
    }

    func testSmallMovementAndDirectionReversal() {
        var input = CrownPageInput()
        XCTAssertNil(input.rotate(by:0.3,enabled:true))
        XCTAssertNil(input.rotate(by:-0.3,enabled:true))
        XCTAssertEqual(input.rotate(by:-0.3,enabled:true), .previous)
        input.endRotation()
        XCTAssertNil(input.rotate(by:.nan,enabled:true))
        XCTAssertNil(input.rotate(by:.infinity,enabled:true))
        XCTAssertNil(input.rotate(by:0.3,enabled:true))
        input.endRotation()
        XCTAssertNil(input.rotate(by:0.3,enabled:true))
    }
}
