import XCTest
@testable import BookSlideCore

final class ReaderNoteDraftStoreTests: XCTestCase {
    func testDraftsSurviveReopeningAndRemainSeparateForEachBookAndType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let book = UUID(), other = UUID(), store = ReaderNoteDraftStore(libraryDirectory:root)
        var item = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2/1:0)",quote:"原文",chapter:"一",progress:0.1,note:"未完成的想法")
        try store.save(ReaderTextNoteDraft(bookID:book,annotation:item))
        item.note = "修改后的草稿\n下一次继续"
        try store.save(ReaderTextNoteDraft(bookID:book,annotation:item))
        let reopened = ReaderNoteDraftStore(libraryDirectory:root)
        XCTAssertEqual(try reopened.textDrafts(bookID:book).map(\.annotation),[item])
        XCTAssertTrue(try reopened.textDrafts(bookID:other).isEmpty)
        XCTAssertTrue(try reopened.inkDrafts(bookID:book).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:store.directory.appendingPathComponent(book.uuidString).path).count,1)
        try reopened.remove(bookID:other,id:UUID(uuidString:item.id)!,ink:false)
        XCTAssertEqual(try reopened.textDrafts(bookID:book).count,1)
        try reopened.remove(bookID:book,id:UUID(uuidString:item.id)!,ink:false)
        XCTAssertTrue(try reopened.textDrafts(bookID:book).isEmpty)
    }

    func testInkDraftAtomicallyKeepsPageAndEditableDataTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ReaderNoteDraftStore(libraryDirectory:root), book = UUID()
        let anchor = ReaderPageAnchor(locator:"epubcfi(/6/2!/4/2/1:0)",chapter:"一",progress:0.2,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"paper")
        let note = ReaderPageNote(assetID:UUID(),anchor:anchor)
        try store.save(ReaderInkNoteDraft(bookID:book,note:note,page:Data("original page".utf8),drawing:Data("strokes".utf8)))
        XCTAssertThrowsError(try store.save(ReaderInkNoteDraft(bookID:book,note:note,page:Data(),drawing:Data("replacement".utf8))))
        let restored = try XCTUnwrap(store.inkDrafts(bookID:book).first)
        XCTAssertEqual(restored.page,Data("original page".utf8))
        XCTAssertEqual(restored.drawing,Data("strokes".utf8))
        XCTAssertEqual(restored.note,note)
        var invalid = ReaderAnnotation(cfi:"cfi",quote:"quote",chapter:"",progress:0)
        invalid.id = "../../library"
        XCTAssertThrowsError(try store.save(ReaderTextNoteDraft(bookID:book,annotation:invalid)))
    }
}
