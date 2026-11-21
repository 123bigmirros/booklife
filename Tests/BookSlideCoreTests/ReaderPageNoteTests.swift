import XCTest
@testable import BookSlideCore

final class ReaderPageNoteTests: XCTestCase {
    private struct Book: Codable { var title: String; var pageNotes: [ReaderPageNote]? }
    func testLegacyBooksDecodeWithoutHandwriting() throws {
        let book = try JSONDecoder().decode(Book.self,from:Data(#"{"title":"旧书"}"#.utf8))
        XCTAssertNil(book.pageNotes)
    }
    func testImmutableInkAssetsKeepLibraryBackupRecoverableAfterEditing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let assets = ReaderPageNoteStore(libraryDirectory:root), library = LibraryIndexStore(directory:root)
        let first = ReaderPageNoteFiles(drawing:Data("pressure and tilt".utf8),page:Data("original page".utf8),ink:Data("ink".utf8),preview:Data("combined preview".utf8))
        let firstID = try assets.save(first)
        let anchor = ReaderPageAnchor(locator:"epubcfi(/6/2!/4/2/1:0)",chapter:"章节",progress:0.3,referenceX:10,referenceY:-4,viewportWidth:820,viewportHeight:1000,layoutKey:"original layout")
        var note = ReaderPageNote(assetID:firstID,anchor:anchor)
        try library.save([Book(title:"书",pageNotes:[note])])
        var edited = first; edited.drawing = Data("edited strokes".utf8)
        note.assetID = try assets.save(edited)
        try library.save([Book(title:"书",pageNotes:[note])])
        XCTAssertNotEqual(firstID,note.assetID)
        XCTAssertEqual(try assets.load(firstID).drawing,first.drawing)
        XCTAssertEqual(try assets.load(note.assetID).drawing,edited.drawing)
        try Data("damaged".utf8).write(to:root.appendingPathComponent("library.json"))
        let recovered = try XCTUnwrap(library.load([Book].self))
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.value.first?.pageNotes?.first?.anchor,anchor)
        let recoveredID = try XCTUnwrap(recovered.value.first?.pageNotes?.first?.assetID)
        XCTAssertEqual(try assets.load(recoveredID).page,first.page)
    }
    func testInvalidAssetsCannotReplaceAnExistingDrawingAndPathsAreRestricted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ReaderPageNoteStore(libraryDirectory:root)
        let data = Data("retained".utf8)
        let id = try store.save(.init(drawing:data,page:data,ink:data,preview:data))
        XCTAssertThrowsError(try store.save(.init(drawing:Data(),page:data,ink:data,preview:data)))
        XCTAssertEqual(try store.load(id).drawing,data)
        XCTAssertThrowsError(try store.image(id,name:"../library.json"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:store.directory.path),[id.uuidString])
    }
}
