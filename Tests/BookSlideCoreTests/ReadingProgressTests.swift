import XCTest
@testable import BookSlideCore

final class ReadingProgressTests: XCTestCase {
    func testFolderChoiceReplacementAndDisconnectPreserveLocalProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let first = root.appendingPathComponent("我的阅读"), second = root.appendingPathComponent("another-folder")
        for url in [first,second] { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true) }
        let store = ProgressStore(directory:root.appendingPathComponent("local")), r = record(time:100)
        try store.merge([r]); try store.selectCloudFolder(first); try store.syncCloud()
        try store.selectCloudFolder(second); try store.syncCloud()
        XCTAssertEqual(store.cloudFolderName, "another-folder")
        XCTAssertEqual(try ProgressStore(directory:second.appendingPathComponent("BookSlideProgress-v1")).records(), [r])
        try store.disconnectCloud(); try store.disconnectCloud()
        XCTAssertFalse(store.cloudConfigured)
        XCTAssertEqual(try store.records(), [r])
        try store.migrateLegacyCloudFolder(first)
        XCTAssertFalse(store.cloudConfigured, "Turning off sync must survive relaunch and legacy migration")
    }
    func testLegacyFolderMigrationOnlyAppliesToExistingInstallations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        let fresh = ProgressStore(directory:root.appendingPathComponent("fresh"))
        try fresh.migrateLegacyCloudFolder(legacy)
        XCTAssertFalse(fresh.cloudConfigured)
        try fresh.merge([record(time:100)]); try fresh.migrateLegacyCloudFolder(legacy)
        XCTAssertFalse(fresh.cloudConfigured, "New progress must not opt a new user into a personal folder")
        let existing = ProgressStore(directory:root.appendingPathComponent("existing"))
        try existing.merge([record(time:100)])
        try Data("expired old bookmark".utf8).write(to:existing.directory.appendingPathComponent("cloud-folder.bookmark"))
        try existing.migrateLegacyCloudFolder(legacy)
        XCTAssertTrue(existing.cloudConfigured)
        XCTAssertEqual(existing.cloudFolderName,"legacy")
        XCTAssertEqual(try String(contentsOf:existing.directory.appendingPathComponent("legacy-cloud-folder.bookmark")),"expired old bookmark")
        let chosen = ProgressStore(directory:root.appendingPathComponent("chosen"))
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try chosen.merge([record(time:100)]); try chosen.selectCloudFolder(other)
        try chosen.migrateLegacyCloudFolder(legacy)
        XCTAssertEqual(chosen.cloudFolderName,"other", "Never overwrite an explicit new choice")
    }
    private func record(_ writer: UUID = UUID(), time: Double, value: Double = 0.4) -> ReadingProgress {
        ReadingProgress(bookKey:String(repeating:"a",count:64),deviceID:writer,deviceName:"Test",updatedAt:Date(timeIntervalSince1970:time),anchor:ContentAnchor(href:"Text/one.xhtml",quote:"阅读位置",fraction:value),cfi:"epubcfi(/6/2!/4/2/1:4)",progress:value)
    }
    func testOfflineMergePreservesBackwardReadingAndRejectsStaleWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let a = ProgressStore(directory:root.appendingPathComponent("a")), b = ProgressStore(directory:root.appendingPathComponent("b"))
        let writer = UUID(), old = record(writer,time:100,value:0.9), backward = record(writer,time:200,value:0.2), other = record(time:150,value:0.6)
        try a.merge([old]); try b.merge([backward,other]); try a.merge(b.records()); try a.merge([old])
        XCTAssertEqual(try a.latest(bookKey:old.bookKey),backward)
        XCTAssertEqual(try a.records().count,2)
        try b.merge(a.records()); XCTAssertEqual(try b.latest(bookKey:old.bookKey),backward)
    }
    func testCloudFolderRoundTripAndCorruptFileDoesNotDestroyLocalRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let folder = root.appendingPathComponent("cloud"), a = ProgressStore(directory:root.appendingPathComponent("a")), b = ProgressStore(directory:root.appendingPathComponent("b"))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try a.selectCloudFolder(folder); try b.selectCloudFolder(folder)
        let first=record(time:100), second=record(time:200,value:0.1)
        try a.merge([first]); try a.syncCloud(); try b.syncCloud()
        XCTAssertEqual(try b.latest(bookKey:first.bookKey),first)
        try b.merge([second]); try b.syncCloud(); try a.syncCloud()
        XCTAssertEqual(try a.latest(bookKey:first.bookKey),second)
        try Data("broken".utf8).write(to:a.directory.appendingPathComponent("broken.json"))
        XCTAssertEqual(try a.records().count,2)
        try a.disconnectCloud(); XCTAssertFalse(a.cloudConfigured)
        XCTAssertEqual(try a.latest(bookKey:first.bookKey),second)
    }
    func testAuthenticationValidationAndSignedExchange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ProgressStore(directory:root), token="progress-test-key", path="/v3/progress", r=record(time:100)
        let router = ProgressRouter(token:token,store:store), body=try JSONEncoder().encode([r])
        XCTAssertEqual(router.handle(HTTPRequest(method:"POST",path:path,headers:[:],body:body))?.status,401)
        let headers = RequestAuthentication.headers(method:"POST",path:path,body:body,token:token)
        let response = try XCTUnwrap(router.handle(HTTPRequest(method:"POST",path:path,headers:headers,body:body)))
        XCTAssertEqual(response.reply.progressRecords,[r]); XCTAssertEqual(response.status,200)
        XCTAssertTrue(RequestAuthentication.verifyResponse(status:200,body:response.body,signature:response.extraHeaders["X-BookSlide-Signature"],nonce:headers["x-bookslide-nonce"]!,token:token))
        let invalid=ReadingProgress(bookKey:"../../outside",deviceID:UUID(),deviceName:"bad",anchor:r.anchor,progress:0)
        try store.merge([invalid]); XCTAssertEqual(try store.records().count,1)
    }
    func testLargeProgressBodyIsAllowedOnlyOnProgressEndpoint() throws {
        let body=Data(repeating:32,count:8000)
        func wire(_ path: String) -> Data { Data("POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)+body }
        var progress=HTTPParser(); XCTAssertEqual(try progress.append(wire("/v3/progress"))?.body.count,8000)
        var turn=HTTPParser(); XCTAssertThrowsError(try turn.append(wire("/v3/turn")))
    }
    func testDeviceIdentityAndDeterministicTieBreak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ProgressStore(directory:root)
        XCTAssertEqual(try store.deviceID(source:"mac"),try store.deviceID(source:"mac"))
        XCTAssertNotEqual(try store.deviceID(source:"mac"),try store.deviceID(source:"terminal"))
        let a=record(time:100), b=record(time:100)
        try store.merge([a,b]); let first=try store.latest(bookKey:a.bookKey)
        try store.merge([b,a]); XCTAssertEqual(try store.latest(bookKey:a.bookKey),first)
        XCTAssertEqual(ContentAnchor.canonical(" A\n中\u{202e} 文 😀 "),"A中文😀")
    }
}
