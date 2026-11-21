import XCTest
@testable import BookSlideCore

final class LibrarySharingTests: XCTestCase {
    func testCatalogDefaultsLegacyEntriesToEPUBAndRoundTripsPDF() throws {
        let id = UUID()
        let legacy = try JSONSerialization.data(withJSONObject:[
            "id":id.uuidString, "title":"旧书", "author":"作者", "lastRead":0
        ])
        XCTAssertEqual(try JSONDecoder().decode(SharedLibraryBook.self,from:legacy).format, .epub)
        let pdf = SharedLibraryBook(id:id,title:"PDF 书",author:"作者",lastRead:Date(),format:.pdf)
        let encoded = try JSONEncoder().encode(pdf)
        XCTAssertEqual(try JSONDecoder().decode(SharedLibraryBook.self,from:encoded).format, .pdf)
    }

    @MainActor func testAuthenticatedCatalogAndBoundedDownload() async throws {
        let token = "library-test-key", id = UUID()
        let data = Data(repeating:65,count:LibraryRouter.chunkSize+37)
        var loads = 0
        let router = LibraryRouter(token:token,catalog:{ [SharedLibraryBook(id:id,title:"真实图书",author:"作者",lastRead:Date(timeIntervalSince1970:0))] },archive:{ _ in loads += 1; return data })
        func request(_ path: String) -> HTTPRequest { HTTPRequest(method:"GET",path:path,headers:RequestAuthentication.headers(method:"GET",path:path,token:token)) }
        let unauthorized = await router.handle(HTTPRequest(method:"GET",path:"/v3/library",headers:[:]))
        XCTAssertEqual(unauthorized?.status,401); XCTAssertNil(unauthorized?.reply.library)
        let catalog = await router.handle(request("/v3/library"))
        XCTAssertEqual(catalog?.reply.library?.map(\.title),["真实图书"])
        var downloaded = Data()
        for offset in [0,LibraryRouter.chunkSize] {
            let req = request("/v3/library/\(id)/\(offset)")
            let handled = await router.handle(req)
            let response = try XCTUnwrap(handled)
            XCTAssertTrue(RequestAuthentication.verifyResponse(status:response.status,body:response.body,signature:response.extraHeaders["X-BookSlide-Signature"],nonce:req.headers["x-bookslide-nonce"]!,token:token))
            let chunk = try XCTUnwrap(response.reply.libraryChunk)
            XCTAssertEqual(chunk.offset,offset); XCTAssertEqual(chunk.total,data.count)
            downloaded.append(chunk.data)
        }
        XCTAssertEqual(downloaded,data); XCTAssertEqual(loads,1)
        for path in ["/v3/library/\(UUID())/0","/v3/library/../../0","/v3/library/\(id)/-1"] {
            let invalid = await router.handle(request(path)); XCTAssertEqual(invalid?.status,404)
        }
        XCTAssertEqual(loads,1)
    }
}
