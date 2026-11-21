import XCTest
@testable import BookSlideCore

final class ReadingSessionTests: XCTestCase {
    func testFractionalWireCompatibilityNeverBecomesAnOldReceiverPageTurn() throws {
        struct LegacyCommand: Decodable { let scrollLines: Int? }
        let integer = try JSONEncoder().encode(TurnCommand(direction:.next,scrollLines:1))
        XCTAssertEqual(try JSONDecoder().decode(LegacyCommand.self,from:integer).scrollLines,1)
        let fractional = try JSONEncoder().encode(TurnCommand(direction:.next,scrollLines:1.0/16))
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyCommand.self,from:fractional))
        XCTAssertEqual(try JSONDecoder().decode(TurnCommand.self,from:fractional).scrollLines,1.0/16)
        let legacy = ReadingSnapshot(sessionID:UUID(),bookID:UUID(),title:"Old",page:1,pageCount:3)
        XCTAssertNil(try JSONDecoder().decode(ReadingSnapshot.self,from:JSONEncoder().encode(legacy)).supportsFractionalScroll)
    }
    func testFineScrollValidationAndActualViewportConfirmation() async throws {
        let session = UUID(), book = UUID()
        var offset = 0.0, calls = 0
        let router = ReadingRouter(token:token,snapshot:{
            ReadingSnapshot(sessionID:session,bookID:book,title:"image page",page:1,pageCount:3,locator:"same-image",canGoPrevious:offset > 0,readingMode:.scroll,viewportOffset:offset)
        },readiness:{nil},turn:{_ in XCTFail("Fine scroll must not become a page jump"); return nil},scroll:{direction,lines in
            calls += 1; offset += Double(lines*30)*(direction == .next ? 1 : -1); return nil
        })
        for lines in [-1.0,0,0.01,5,Double(Int.max)] {
            let result = await router.handle(try request(TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:lines)),now:now)
            XCTAssertEqual(result.status,400)
        }
        let command = TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:2)
        let result = await router.handle(try request(command),now:now)
        XCTAssertTrue(result.reply.ok); XCTAssertEqual(offset,60); XCTAssertEqual(calls,1)
        let duplicate = await router.handle(try request(command),now:now)
        XCTAssertEqual(duplicate.reply,result.reply); XCTAssertEqual(calls,1)
        let reverse = await router.handle(try request(TurnCommand(direction:.previous,sentAt:1000,sessionID:session,scrollLines:1)),now:now)
        XCTAssertTrue(reverse.reply.ok); XCTAssertEqual(offset,30)
    }
    func testFractionalInputIsAcceptedOnceWithoutInventingVisibleMovement() async throws {
        let session = UUID()
        var position = ReadingSnapshot(sessionID:session,bookID:UUID(),title:"Terminal",page:1,pageCount:5,readingMode:.scroll)
        position.supportsFractionalScroll = true
        var amount = 0.0
        let router = ReadingRouter(token:token,snapshot:{position},readiness:{nil},turn:{_ in XCTFail();return nil},scroll:{direction,lines in
            amount += lines*(direction == .next ? 1 : -1); return nil
        })
        let command = TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:0.25)
        let response = await router.handle(try request(command),now:now)
        XCTAssertTrue(response.reply.ok); XCTAssertEqual(response.reply.reading?.page,1); XCTAssertEqual(amount,0.25)
        _ = await router.handle(try request(command),now:now); XCTAssertEqual(amount,0.25)
        // A stale at-start flag must not block braking an accepted forward tail.
        let reverse = await router.handle(try request(TurnCommand(direction:.previous,sentAt:1000,sessionID:session,scrollLines:0.25)),now:now)
        XCTAssertTrue(reverse.reply.ok); XCTAssertEqual(amount,0)
        position.supportsFractionalScroll = nil
        let legacy = await router.handle(try request(TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:0.25)),now:now)
        XCTAssertEqual(legacy.status,409); XCTAssertEqual(amount,0)
    }
    func testLargerCrownBatchRequiresAdvertisedReceiverSupport() async throws {
        let session = UUID()
        var position = ReadingSnapshot(sessionID:session,bookID:UUID(),title:"Reader",page:1,pageCount:50,readingMode:.scroll)
        position.supportsFractionalScroll = true
        var received = 0.0
        let router = ReadingRouter(token:token,snapshot:{position},readiness:{nil},turn:{_ in XCTFail();return nil},scroll:{_,lines in received += lines; return nil})
        XCTAssertEqual(position.scrollBatchLimit,4)
        let old = await router.handle(try request(TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:12)),now:now)
        XCTAssertEqual(old.status,400); XCTAssertEqual(received,0)
        position.maxScrollLines = 16
        let encoded = try JSONEncoder().encode(position)
        XCTAssertEqual(try JSONDecoder().decode(ReadingSnapshot.self,from:encoded).scrollBatchLimit,16)
        let command = TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:12)
        let accepted = await router.handle(try request(command),now:now)
        XCTAssertTrue(accepted.reply.ok); XCTAssertEqual(received,12)
        _ = await router.handle(try request(command),now:now); XCTAssertEqual(received,12)
        let oversized = await router.handle(try request(TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:17)),now:now)
        XCTAssertEqual(oversized.status,400); XCTAssertEqual(received,12)
    }
    func testFineScrollCannotFallBackToBigJumpAndLegacyStillDecodes() async throws {
        let session = UUID()
        let router = ReadingRouter(token:token,snapshot:{self.snapshot(session:session)},readiness:{nil},turn:{_ in XCTFail("No implicit fallback"); return nil})
        let result = await router.handle(try request(TurnCommand(direction:.next,sentAt:1000,sessionID:session,scrollLines:1)),now:now)
        XCTAssertEqual(result.status,409)
        let old = TurnCommand(direction:.next,sentAt:1000,sessionID:session)
        let decoded = try JSONDecoder().decode(TurnCommand.self,from:JSONEncoder().encode(old))
        XCTAssertNil(decoded.scrollLines)
    }
    func testReadingModeSurvivesWatchStateAndAcceptsLegacySnapshots() throws {
        let position = ReadingSnapshot(sessionID:UUID(),bookID:UUID(),title:"Book",page:1,pageCount:20,readingMode:.scroll)
        let encoded = try JSONEncoder().encode(position)
        XCTAssertEqual(try JSONDecoder().decode(ReadingSnapshot.self,from:encoded).readingMode,.scroll)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        legacy.removeValue(forKey:"readingMode")
        let decoded = try JSONDecoder().decode(ReadingSnapshot.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(decoded.readingMode)
        XCTAssertEqual(decoded.sessionID,position.sessionID)
    }
    private let now = Date(timeIntervalSince1970:1000)
    private let token = "reader-test-token"
    private func request(_ command: TurnCommand, token: String? = nil) throws -> HTTPRequest {
        let body = try JSONEncoder().encode(command)
        var headers = RequestAuthentication.headers(method:"POST",path:"/v3/turn",body:body,token:token ?? self.token,now:now)
        headers["content-type"] = "application/json"
        return HTTPRequest(method:"POST",path:"/v3/turn",headers:headers,body:body)
    }
    private func snapshot(session: UUID, page: Int = 1, locator: String = "cfi-1") -> ReadingSnapshot {
        ReadingSnapshot(sessionID:session,bookID:UUID(),title:"Book",page:page,pageCount:4,locator:locator)
    }
    func testPhoneRejectsPreviousControlSessionAndWrongTarget() {
        let id = UUID(), control = UUID(), session = UUID()
        let state = PhoneControlState(receiverID:id,receiverName:"Mac",controlID:control,reading:snapshot(session:session))
        let command = TurnCommand(direction:.next,sentAt:1000,sessionID:session)
        XCTAssertTrue(state.accepts(WatchTurnRequest(controlID:control,receiverID:id,command:command),now:now))
        XCTAssertFalse(state.accepts(WatchTurnRequest(controlID:UUID(),receiverID:id,command:command),now:now))
        XCTAssertFalse(state.accepts(WatchTurnRequest(controlID:control,receiverID:UUID(),command:command),now:now))
        XCTAssertFalse(state.accepts(WatchTurnRequest(controlID:control,receiverID:id,command:command),now:now.addingTimeInterval(11)))
        var stopped = state; stopped.controlID = nil
        XCTAssertFalse(stopped.accepts(WatchTurnRequest(controlID:control,receiverID:id,command:command),now:now))
    }
    func testNewBookAndLegacyCommandsCannotTurnReader() async throws {
        let session = UUID()
        var calls = 0
        let router = ReadingRouter(token:token,snapshot:{self.snapshot(session:session)},readiness:{nil},turn:{_ in calls += 1; return nil})
        for command in [TurnCommand(direction:.next,sentAt:1000),TurnCommand(direction:.next,sentAt:1000,sessionID:UUID())] {
            let result = await router.handle(try request(command),now:now)
            XCTAssertEqual(result.status,409)
        }
        XCTAssertEqual(calls,0)
    }
    func testConfirmedCFIAndDuplicateAcrossChapterBoundary() async throws {
        let session = UUID()
        var current = snapshot(session:session,page:4,locator:"chapter-1-last")
        // A chapter transition can reset its page number; the CFI is authoritative.
        current = ReadingSnapshot(sessionID:session,bookID:UUID(),title:"Book",page:4,pageCount:4,locator:"chapter-1-last",canGoNext:true)
        var calls = 0
        let router = ReadingRouter(token:token,snapshot:{current},readiness:{nil},turn:{_ in
            calls += 1; current = self.snapshot(session:session,page:1,locator:"chapter-2-first"); return nil
        })
        let command = TurnCommand(direction:.next,sentAt:1000,sessionID:session)
        let first = await router.handle(try request(command),now:now)
        let duplicate = await router.handle(try request(command),now:now.addingTimeInterval(1))
        XCTAssertTrue(first.reply.ok)
        XCTAssertEqual(first.reply.reading?.locator,"chapter-2-first")
        XCTAssertEqual(first.reply,duplicate.reply)
        XCTAssertEqual(calls,1)
        let collision = TurnCommand(id:command.id,direction:.previous,sentAt:1000,sessionID:session)
        let conflict = await router.handle(try request(collision),now:now.addingTimeInterval(2))
        XCTAssertEqual(conflict.status,409)
    }
    func testScrollAcceptsContinuedInputButPagedKeepsDebounce() async throws {
        for mode in [ReadingMode.scroll, .paged] {
            let session = UUID(), book = UUID()
            var page = 1
            let router = ReadingRouter(token:token,snapshot:{
                ReadingSnapshot(sessionID:session,bookID:book,title:"Book",page:page,pageCount:20,locator:"line-\(page)",readingMode:mode)
            },readiness:{nil},turn:{_ in page += 1; return nil})
            let first = TurnCommand(direction:.next,sentAt:1000,sessionID:session)
            let result = await router.handle(try request(first),now:now)
            XCTAssertTrue(result.reply.ok)
            let second = TurnCommand(direction:.next,sentAt:1000.2,sessionID:session)
            let continued = await router.handle(try request(second),now:now.addingTimeInterval(0.2))
            XCTAssertEqual(continued.status,mode == .scroll ? 200 : 429)
            let duplicate = await router.handle(try request(first),now:now.addingTimeInterval(0.3))
            XCTAssertEqual(duplicate.reply,result.reply)
            XCTAssertEqual(page,mode == .scroll ? 3 : 2)
        }
    }

    func testNoFalseSuccessWhenEngineDoesNotMove() async throws {
        let session = UUID()
        let router = ReadingRouter(token:token,snapshot:{self.snapshot(session:session)},readiness:{nil},turn:{_ in nil})
        let result = await router.handle(try request(TurnCommand(direction:.next,sentAt:1000,sessionID:session)),now:now)
        XCTAssertFalse(result.reply.ok)
        XCTAssertEqual(result.status,503)
    }
    func testExpiredUnauthorizedAndUnreadyNeverExecute() async throws {
        let session = UUID()
        var calls = 0
        let router = ReadingRouter(token:token,snapshot:{self.snapshot(session:session)},readiness:{"Reader inactive"},turn:{_ in calls += 1; return nil})
        let expired = await router.handle(try request(TurnCommand(direction:.next,sentAt:900,sessionID:session)),now:now)
        XCTAssertEqual(expired.status,408)
        let command = TurnCommand(direction:.next,sentAt:1000,sessionID:session)
        let rejected = await router.handle(try request(command,token:"wrong"),now:now)
        XCTAssertEqual(rejected.status,401)
        let inactive = await router.handle(try request(command),now:now)
        XCTAssertEqual(inactive.status,409)
        XCTAssertEqual(calls,0)
    }
    func testStatusWithoutBookStillAllowsPairingAndNeverTurns() async {
        let router = ReadingRouter(token:token,snapshot:{nil},readiness:{"No book"},turn:{_ in XCTFail("Status must not turn"); return nil})
        let request = HTTPRequest(method:"GET",path:"/v3/status",headers:RequestAuthentication.headers(method:"GET",path:"/v3/status",token:token,now:now))
        let result = await router.handle(request,now:now)
        XCTAssertTrue(result.reply.ok); XCTAssertNil(result.reply.reading)
    }
    func testWatchStateContainsNoReceiverCredentials() throws {
        let state = PhoneControlState(receiverID:UUID(),receiverName:"Mac",controlID:UUID(),reading:snapshot(session:UUID()))
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertNil(object["token"]); XCTAssertNil(object["endpoint"])
        XCTAssertEqual(try JSONDecoder().decode(PhoneControlState.self,from:data),state)
    }
}
