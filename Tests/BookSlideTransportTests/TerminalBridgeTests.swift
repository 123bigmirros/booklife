import XCTest
import BookSlideCore
@testable import BookSlideTransport

final class TerminalBridgeTests: XCTestCase {
    func testLeaseExpiresAndDoesNotRemoveAnotherReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("lease.json"), owner = UUID(), now = Date()
        try TerminalLease(owner:owner,port:1234,token:String(repeating:"a",count:32),now:now).save(to:file)
        XCTAssertEqual(TerminalLease.load(from:file,now:now)?.owner,owner)
        XCTAssertNil(TerminalLease.load(from:file,now:now.addingTimeInterval(7)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        TerminalLease.remove(owner:UUID(),from:file)
        XCTAssertNotNil(TerminalLease.load(from:file))
        try TerminalLease(owner:owner,port:1235,token:String(repeating:"a",count:32)).save(to:file)
        XCTAssertEqual(TerminalLease.load(from:file)?.port,1235)
        TerminalLease.remove(owner:owner,from:file)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    @MainActor func testExistingMacCredentialsForwardToTerminalOnceAndRejectStaleSession() async throws {
        let macToken = "mac-existing-pair", terminalToken = String(repeating:"b",count:32)
        let sid = UUID(), bid = UUID(); var page = 1, turns = 0
        let router = ReadingRouter(token:terminalToken,snapshot:{ ReadingSnapshot(sessionID:sid,bookID:bid,title:"终端图书",page:page,pageCount:8,locator:"page-\(page)",readingMode:.scroll) },readiness:{nil},turn:{ _ in turns += 1; page += 1; return nil },scroll:{ _,lines in turns += 1; page += Int(lines); return nil })
        let terminal = HTTPServer { await router.handle($0) }
        var port: UInt16?
        let ready = expectation(description:"loopback ready")
        terminal.onState = { _,p in if let p { port = p; ready.fulfill() } }
        try terminal.start(port:0,loopbackOnly:true); defer { terminal.stop() }
        await fulfillment(of:[ready],timeout:5)
        let lease = TerminalLease(owner:UUID(),port:try XCTUnwrap(port),token:terminalToken)
        let bridge = TerminalBridge(token:macToken,lease:{lease})
        func request(_ command: TurnCommand?) throws -> HTTPRequest {
            let body = try command.map { try JSONEncoder().encode($0) } ?? Data()
            let path = command == nil ? "/v3/status" : "/v3/turn", method = command == nil ? "GET" : "POST"
            var headers = RequestAuthentication.headers(method:method,path:path,body:body,token:macToken)
            headers["content-type"] = "application/json"
            return HTTPRequest(method:method,path:path,headers:headers,body:body)
        }
        let status = await bridge.handle(try request(nil))
        XCTAssertEqual(status?.reply.reading?.title,"终端图书")
        let command = TurnCommand(direction:.next,sessionID:sid), req = try request(command)
        for _ in 0..<2 {
            let response = await bridge.handle(req)
            XCTAssertEqual(response?.reply.commandID,command.id); XCTAssertTrue(response?.reply.ok == true)
            let signed = try XCTUnwrap(response)
            XCTAssertTrue(RequestAuthentication.verifyResponse(status:signed.status,body:signed.body,signature:signed.extraHeaders["X-BookSlide-Signature"],nonce:req.headers["x-bookslide-nonce"]!,token:macToken))
        }
        XCTAssertEqual(turns,1); XCTAssertEqual(page,2)
        let fine = await bridge.handle(try request(TurnCommand(direction:.next,sessionID:sid,scrollLines:2)))
        XCTAssertTrue(fine?.reply.ok == true); XCTAssertEqual(page,4); XCTAssertEqual(turns,2)
        let stale = await bridge.handle(try request(TurnCommand(direction:.next,sessionID:UUID())))
        XCTAssertEqual(stale?.status,409); XCTAssertEqual(turns,2)
        let denied = await bridge.handle(HTTPRequest(method:"GET",path:"/v3/status",headers:[:]))
        XCTAssertEqual(denied?.status,401)
    }
}
