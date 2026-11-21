import XCTest
@testable import BookSlideCore

final class ReaderAnnotationTests: XCTestCase {
    private struct Book: Codable {
        var title: String
        var bookmarks: [String]
        var annotations: [ReaderAnnotation]?
    }
    func testPreAnnotationLibraryRemainsReadable() throws {
        let book = try JSONDecoder().decode(Book.self,from:Data(#"{"title":"旧书","bookmarks":["original-position"]}"#.utf8))
        XCTAssertNil(book.annotations)
        XCTAssertEqual(book.bookmarks,["original-position"])
    }
    func testAnnotationsSurviveLibrarySaveAndRecoveryWithTheirTextAnchors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryIndexStore(directory:root)
        let items = AnnotationColor.allCases.map {
            ReaderAnnotation(cfi:"epubcfi(/6/2[chapter]!/4/2,/1:0,/1:8)",quote:"读书时的想法 🌱",chapter:"第一章",progress:0.1,color:$0,note:"第一行\n第二行 <script>只是文字</script>")
        }
        try store.save([Book(title:"书",bookmarks:["original-position"],annotations:items)])
        var revised = items; revised[0].note = "修改后的笔记"
        try store.save([Book(title:"书",bookmarks:["original-position"],annotations:revised)])
        XCTAssertEqual(try store.load([Book].self)?.value.first?.annotations,revised)
        try Data("broken".utf8).write(to:root.appendingPathComponent("library.json"))
        let recovered = try XCTUnwrap(store.load([Book].self))
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.value.first?.annotations,items)
        XCTAssertEqual(recovered.value.first?.bookmarks,["original-position"])
    }
}
