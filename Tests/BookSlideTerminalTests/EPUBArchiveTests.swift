import XCTest
@testable import BookSlideTerminal

final class EPUBArchiveTests: XCTestCase {
    func testReopeningAnArchiveRechecksTheSizeAndSignature() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("changed.epub")
        let zipHeader = Data([0x50,0x4b,0x03,0x04,1,2,3])
        try zipHeader.write(to:file)
        XCTAssertEqual(try EPUBArchive.data(at:file),zipHeader)

        // A file may have changed since it was imported. Reject it before loading
        // it into WebKit or caching it for a paired device's library download.
        let handle = try FileHandle(forWritingTo:file)
        try handle.truncate(atOffset:51 * 1024 * 1024)
        try handle.close()
        XCTAssertThrowsError(try EPUBArchive.data(at:file))
        try Data("not a ZIP archive".utf8).write(to:file)
        XCTAssertThrowsError(try EPUBArchive.data(at:file))
    }
}
