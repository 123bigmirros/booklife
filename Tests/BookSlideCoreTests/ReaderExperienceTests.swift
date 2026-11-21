import XCTest
@testable import BookSlideCore

final class ReaderExperienceTests: XCTestCase {
    func testSearchAcceptsSingleCharactersAndSeparatesEmptyResultsFromIdle() {
        XCTAssertEqual(ReaderSearchState.normalized(" \n书\t"), "书")
        XCTAssertTrue(ReaderSearchState.normalized(" \n\t").isEmpty)
        XCTAssertNotEqual(ReaderSearchState.idle.message, ReaderSearchState.complete(0).message)
        XCTAssertNil(ReaderSearchState.complete(1).message)
        XCTAssertNotNil(ReaderSearchState.complete(80).message)
        XCTAssertNotEqual(ReaderSearchState.failed.message, ReaderSearchState.complete(0).message)
    }
    func testImportRejectsWrongTypeEmptyAndInvalidFilesAndFingerprintsContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let a = root.appendingPathComponent("first.epub"), b = root.appendingPathComponent("renamed.EPUB")
        let data = Data([0x50,0x4b,0x03,0x04,1,2,3])
        try data.write(to:a); try data.write(to:b)
        XCTAssertEqual(BookImportFile.fingerprint(try BookImportFile.read(a)), BookImportFile.fingerprint(try BookImportFile.read(b)))
        XCTAssertNotEqual(BookImportFile.fingerprint(data), BookImportFile.fingerprint(data + Data([4])))
        try Data().write(to:a); XCTAssertThrowsError(try BookImportFile.read(a))
        try Data("not an epub".utf8).write(to:a); XCTAssertThrowsError(try BookImportFile.read(a))
        let txt = root.appendingPathComponent("book.txt"); try data.write(to:txt)
        XCTAssertThrowsError(try BookImportFile.read(txt))
    }
}
