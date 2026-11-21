import XCTest
@testable import BookSlideTerminal

final class LibraryCatalogTests: XCTestCase {
    func testHiddenImportStaysOnDiskButLeavesTheCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let book = root.appendingPathComponent("a.epub")
        try Data([1,2,3]).write(to:book)
        let manifest = Data("""
        [{"filename":"a.epub","title":"保留书签的书","author":"甲","lastRead":100,"locator":"cfi","hidden":true}]
        """.utf8)
        try manifest.write(to:root.appendingPathComponent("library.json"))
        XCTAssertTrue(try LibraryCatalog.books(in:root,recentDirectory:root.appendingPathComponent("recent")).isEmpty)
        XCTAssertEqual(try Data(contentsOf:book),Data([1,2,3]))
    }
    func testUsesBookTitlesAndCombinesRecencyWithoutChangingManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recent = root.appendingPathComponent("Recent")
        try FileManager.default.createDirectory(at:recent,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let manifest = Data("""
        [{"filename":"a.epub","title":"图形版最近","author":"甲","lastRead":100,"locator":"cfi"},
         {"filename":"b.epub","title":"终端最近","author":"乙","lastRead":50,"locator":"cfi"},
         {"filename":"c.epub","title":"刚导入但未读","author":"丙","lastRead":999,"locator":""}]
        """.utf8)
        try manifest.write(to:root.appendingPathComponent("library.json"))
        for name in ["a","b","c"] { try Data().write(to:root.appendingPathComponent(name+".epub")) }
        try JSONEncoder().encode(Date(timeIntervalSinceReferenceDate:200)).write(to:recent.appendingPathComponent("b.epub.json"))
        let books = try LibraryCatalog.books(in:root,recentDirectory:recent)
        XCTAssertEqual(books.map(\.title),["终端最近","图形版最近","刚导入但未读"])
        XCTAssertEqual(books.first?.author,"乙")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library.json")),manifest)
    }
    func testMissingLibraryIsEmpty() throws {
        XCTAssertTrue(try LibraryCatalog.books(in:URL(fileURLWithPath:"/tmp/"+UUID().uuidString)).isEmpty)
    }
    func testAppleBooksPackagesAppearWithMetadataAndRecentReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let apple = root.appendingPathComponent("Apple"), recent = root.appendingPathComponent("Recent")
        let book = apple.appendingPathComponent("opaque-id.epub")
        try FileManager.default.createDirectory(at:book,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let metadata = try PropertyListSerialization.data(fromPropertyList:["itemName":"实际书名","artistName":"作者"],format:.binary,options:0)
        try metadata.write(to:book.appendingPathComponent("iTunesMetadata.plist"))
        let date = Date(timeIntervalSinceReferenceDate:123)
        try LibraryCatalog.markRead(book,at:date,recentDirectory:recent)
        let result = try LibraryCatalog.allBooks(appleDirectories:[apple,apple],bookSlideDirectory:root.appendingPathComponent("Missing"),recentDirectory:recent)
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result.first?.title,"实际书名")
        XCTAssertEqual(result.first?.author,"作者")
        XCTAssertEqual(result.first?.source,"Apple Books")
        XCTAssertEqual(result.first?.lastRead,date)
        XCTAssertEqual(try Data(contentsOf:book.appendingPathComponent("iTunesMetadata.plist")),metadata)
    }
}
