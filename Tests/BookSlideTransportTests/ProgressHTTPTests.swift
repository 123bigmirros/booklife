import XCTest
import SystemConfiguration
import BookSlideCore
@testable import BookSlideTransport

final class ProgressHTTPTests: XCTestCase {
    @MainActor func testDeviceExchangeWithLargeSignedPayloadOverRealHTTP() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ProgressStore(directory:root), token=String(repeating:"b",count:32)
        let router=ProgressRouter(token:token,store:store)
        let server=HTTPServer { router.handle($0) ?? HTTPResponse(404,Reply(ok:false,message:"unknown")) }
        let ready=expectation(description:"progress server")
        var port: UInt16?
        server.onState={ _,value in if let value { port=value; ready.fulfill() } }
        try server.start(port:0); defer { server.stop() }
        await fulfillment(of:[ready],timeout:5)
        let host = try XCTUnwrap(SCDynamicStoreCopyLocalHostName(nil) as String?)
        let connection=SavedConnection(receiverID:UUID(),name:"Test",endpoint:"http://\(host).local:\(try XCTUnwrap(port))",token:token)
        let session=ReceiverClient.session(); defer { session.invalidateAndCancel() }
        let record=ReadingProgress(bookKey:String(repeating:"e",count:64),deviceID:UUID(),deviceName:"iPhone",anchor:ContentAnchor(href:"Text/chapter.xhtml",quote:"同一个阅读位置",fraction:0.4),cfi:String(repeating:"a",count:5000),progress:0.4)
        let received=try await ReceiverClient.progress(connection:connection,records:[record],session:session)
        XCTAssertEqual(received,[record]); XCTAssertEqual(try store.latest(bookKey:record.bookKey),record)
        let polled=try await ReceiverClient.progress(connection:connection,records:[],session:session)
        XCTAssertEqual(polled,[record])
    }
}
