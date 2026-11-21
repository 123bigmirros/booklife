import XCTest
@testable import BookSlideCore

final class AutomaticControlTests: XCTestCase {
    private func reading(_ session: UUID = UUID(), name: String = "Mac") -> ReadingSnapshot {
        ReadingSnapshot(sessionID:session,bookID:UUID(),title:"Book",page:1,pageCount:10,readerName:name)
    }
    func testFirstReadySnapshotActivatesWithoutManualStartAndRefreshKeepsID() {
        let receiver = UUID(), snapshot = reading()
        let waiting = PhoneControlState().following(receiverID:receiver,name:"My Mac",reading:nil)
        XCTAssertFalse(waiting.isActive)
        let ready = waiting.following(receiverID:receiver,name:"My Mac",reading:snapshot)
        XCTAssertTrue(ready.isActive)
        let refreshed = ready.following(receiverID:receiver,name:"My Mac",reading:snapshot)
        XCTAssertEqual(refreshed.controlID,ready.controlID)
    }
    func testChangedBookOrTerminalFollowsNewSessionAndRejectsOldCommand() {
        let receiver = UUID(), snapshot = reading()
        let before = PhoneControlState().following(receiverID:receiver,name:"My Mac",reading:snapshot)
        let request = WatchTurnRequest(controlID:before.controlID!,receiverID:receiver,command:TurnCommand(direction:.next,sessionID:snapshot.sessionID))
        let terminal = before.following(receiverID:receiver,name:"My Mac",reading:reading(name:"终端"))
        XCTAssertTrue(terminal.isActive)
        XCTAssertNotEqual(terminal.controlID,before.controlID)
        XCTAssertFalse(terminal.accepts(request))
        XCTAssertEqual(terminal.targetName,"My Mac · 终端")
    }
    func testDisconnectCannotShowReadyAndRecoveryCreatesFreshControl() {
        let receiver = UUID(), snapshot = reading()
        let ready = PhoneControlState().following(receiverID:receiver,name:"Mac",reading:snapshot)
        let offline = ready.suspended("正在恢复连接")
        XCTAssertFalse(offline.isActive)
        XCTAssertNil(offline.controlID)
        let recovered = offline.following(receiverID:receiver,name:"Mac",reading:snapshot)
        XCTAssertTrue(recovered.isActive)
        XCTAssertNotEqual(recovered.controlID,ready.controlID)
        let closed = recovered.following(receiverID:receiver,name:"Mac",reading:nil)
        XCTAssertFalse(closed.isActive); XCTAssertNil(closed.reading)
    }
    func testStatusDoesNotAdvertiseHiddenOrInactiveReaderAsReady() async {
        let token = "test", snapshot = reading()
        let router = ReadingRouter(token:token,snapshot:{snapshot},readiness:{"请展开阅读窗口"},turn:{_ in XCTFail("Status never turns"); return nil})
        let request = HTTPRequest(method:"GET",path:"/v3/status",headers:RequestAuthentication.headers(method:"GET",path:"/v3/status",token:token))
        let response = await router.handle(request)
        XCTAssertEqual(response.status,409); XCTAssertFalse(response.reply.ok)
        XCTAssertEqual(response.reply.message,"请展开阅读窗口")
    }
    func testSameSessionIDOnAnotherDeviceDoesNotKeepOldControl() {
        let snapshot = reading()
        let first = PhoneControlState().following(receiverID:UUID(),name:"Mac",reading:snapshot)
        let second = first.following(receiverID:UUID(),name:"iPad",reading:snapshot)
        XCTAssertNotEqual(first.controlID,second.controlID)
    }
}
