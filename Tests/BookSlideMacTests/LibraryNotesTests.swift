import XCTest
import AppKit
import BookSlideCore
@testable import BookSlideMac

@MainActor final class LibraryNotesTests: XCTestCase {
    func testReadingViewportPersistsAndOldSessionCannotOverwriteAnotherBooksCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let id = try XCTUnwrap(reader.books.first?.id)
        reader.currentID = id
        let viewport: [String:Any] = ["locator":"epubcfi(/6/4!/4/12/1:0)","point":["x":16,"y":25.25],"mode":"scroll","layoutKey":"typography-and-size"]
        var position: [String:Any] = ["session":reader.annotationSessionID.uuidString,"mode":"scroll","locator":"epubcfi(/6/4!/4/12/1:0)","chapter":"第二章","page":2,"pageCount":10,"progress":0.4,"canGoNext":true,"canGoPrevious":true,"viewport":viewport]
        reader.acceptPosition(position); reader.save()
        let saved = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first { $0.id == id })
        XCTAssertEqual(saved.readingViewport?.point?.y,25.25)
        XCTAssertEqual(saved.readingViewport?.locator,saved.locator)
        position["session"] = UUID().uuidString
        position["locator"] = "stale-chapter-start"
        position["progress"] = 0
        reader.acceptPosition(position)
        XCTAssertEqual(reader.currentBook?.locator,saved.locator)
        XCTAssertEqual(reader.position?.progress,0.4)
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(saved)) as! [String:Any]
        legacy.removeValue(forKey:"readingViewport")
        let decoded = try JSONDecoder().decode(LibraryBook.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(decoded.readingViewport)
        XCTAssertEqual(decoded.locator,saved.locator)
        let bookmark = ReaderBookmark(id:saved.locator,title:"第二章",progress:0.4,viewport:saved.readingViewport)
        XCTAssertTrue(reader.setReaderBookmark(bookmark,present:true))
        XCTAssertEqual(reader.currentBook?.bookmarks.first?.viewport?.point?.y,25.25)
    }
    func testProgressWithinOneLongParagraphUsesTheVisibleCharacterAnchor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        let key = ReadingProgress.bookKey(package:Data("precise-position".utf8))
        reader.books[0].progressKey = key; reader.currentID = reader.books[0].id
        for offset in [2000,2100] {
            let precise = "epubcfi(/6/4!/4/4/1:\(offset))"
            let anchor: [String:Any] = ["href":"chapter.xhtml","quote":"正在读的这句话","fraction":Double(offset)/4000]
            let viewport: [String:Any] = ["locator":precise,"mode":"scroll","layoutKey":"layout","anchor":anchor]
            reader.acceptPosition(["mode":"scroll","locator":"epubcfi(/6/4!/4/4/1:0)","chapter":"长段落","page":1,"pageCount":10,"progress":0.4,"userDriven":true,"canGoNext":true,"canGoPrevious":true,"viewport":viewport])
            let saved = try XCTUnwrap(reader.progressStore.latest(bookKey:key))
            XCTAssertEqual(saved.cfi,precise)
            XCTAssertEqual(saved.anchor.fraction,Double(offset)/4000)
            XCTAssertEqual(reader.lastRecordedLocator,precise)
        }
    }
    func testSearchAcrossBooksMatchesThoughtsAliasesAndMultipleTermsAndExcludesHiddenBooks() {
        let entity = BookEntity(name:"林川",kind:.person,aliases:["青川客"])
        var a = ReaderAnnotation(cfi:"a",quote:"阅读原文",chapter:"第一章",progress:0.8,note:"耐心帮助理解")
        a.entityIDs = [entity.id]
        var question = ReaderAnnotation(cfi:"b",quote:"",chapter:"第二章",progress:0.3,note:"如何理解不确定性？")
        question.intent = .question
        var hidden = LibraryBook(id:UUID(),title:"已隐藏",author:"",filename:"",annotations:[a])
        hidden.hidden = true
        let books = [LibraryBook(id:UUID(),title:"山河",author:"甲",filename:"",annotations:[a],knowledgeEntities:[entity]),
                     LibraryBook(id:UUID(),title:"思考",author:"乙",filename:"",annotations:[question]),hidden]
        let records = LibraryNotes.records(in:books)
        XCTAssertEqual(records.count,2)
        XCTAssertEqual(LibraryNotes.filtered(records,query:"理解").count,2)
        XCTAssertEqual(LibraryNotes.filtered(records,query:"  青川客  耐心\n").map(\.note.id),[a.id])
        XCTAssertTrue(LibraryNotes.filtered(records,query:"不存在").isEmpty)
        XCTAssertEqual(LibraryNotes.filtered(records,filter:.questions).map(\.note.id),[question.id])
        XCTAssertEqual(LibraryNotes.filtered(records,bookID:books[1].id).count,1)
    }
    func testMarkdownPreservesSourcesMultilineQuotesResponsesAndStableIDs() {
        XCTAssertFalse(NoteMarkdownDocument.readableContentTypes[0].isDynamic)
        XCTAssertTrue(NoteMarkdownDocument.readableContentTypes[0].conforms(to:.plainText))
        var question = ReaderAnnotation(cfi:"q",quote:"第一行\n第二行",chapter:"第一章",progress:0.1,note:"为什么？")
        question.intent = .question
        var answer = ReaderAnnotation(cfi:"a",quote:"",chapter:"第二章",progress:0.8,note:"我的回答")
        answer.responseToID = question.id
        let book = LibraryBook(id:UUID(),title:"书名",author:"作者",filename:"",annotations:[answer,question])
        let records = LibraryNotes.records(in:[book])
        let markdown = NoteMarkdownExport.render(records,title:"读书笔记")
        XCTAssertTrue(markdown.contains("> 第一行\n> 第二行"))
        XCTAssertTrue(markdown.contains("作者：作者"))
        XCTAssertTrue(markdown.contains("我的回答"))
        XCTAssertTrue(markdown.contains("[原疑问](#note-\(book.id.uuidString)-\(question.id))"))
        XCTAssertTrue(markdown.contains("<!-- BookSlide \(book.id.uuidString)/\(question.id) -->"))
        XCTAssertLessThan(markdown.range(of:"为什么？")!.lowerBound,markdown.range(of:"我的回答")!.lowerBound)
        let single = NoteMarkdownExport.render(records.filter { $0.note.id == answer.id },title:"回应")
        XCTAssertFalse(single.contains("[原疑问]("))
        XCTAssertTrue(single.contains("原疑问未包含"))
    }
    func testInkExportWritesPortableImageAndDoesNotReplaceMarkdownWhenAssetMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let png = Data([137,80,78,71])
        let store = ReaderPageNoteStore(libraryDirectory:root)
        let asset = try store.save(ReaderPageNoteFiles(drawing:Data([1]),page:png,ink:png,preview:png))
        let anchor = ReaderPageAnchor(locator:"cfi",chapter:"手写章",progress:0.2,referenceX:0,referenceY:0,viewportWidth:100,viewportHeight:100,layoutKey:"x")
        let note = ReaderPageNote(assetID:asset,anchor:anchor)
        let book = LibraryBook(id:UUID(),title:"书",author:"作者",filename:"",pageNotes:[note])
        let records = LibraryNotes.records(in:[book]), destination = root.appendingPathComponent("我的笔记.md")
        try NoteMarkdownExport.write(records,title:"笔记",to:destination,libraryDirectory:root)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("我的笔记-assets/\(asset.uuidString).png")),png)
        let before = try String(contentsOf:destination,encoding:.utf8)
        XCTAssertTrue(before.contains(asset.uuidString + ".png"))
        try FileManager.default.removeItem(at:store.directory)
        XCTAssertThrowsError(try NoteMarkdownExport.write(records,title:"改写",to:destination,libraryDirectory:root))
        XCTAssertEqual(try String(contentsOf:destination,encoding:.utf8),before)
        XCTAssertEqual(NoteMarkdownExport.safeFilename("../../"),"读书笔记")
    }
    func testReturningToEarlierChapterKeepsLaterNotesAndReadHorizonAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), id = UUID()
        let note = ReaderAnnotation(cfi:"later",quote:"后文摘录",chapter:"后文",progress:0.75,note:"已写下的想法")
        reader.books = [LibraryBook(id:id,title:"书",author:"",filename:"",progress:0.8,annotations:[note])]
        reader.currentID = id
        reader.acceptPosition(["mode":"scroll","locator":"earlier","chapter":"前文","page":1,"pageCount":10,"progress":0.2,"canGoNext":true,"canGoPrevious":true])
        XCTAssertEqual(reader.currentBook?.progress,0.2)
        XCTAssertEqual(reader.currentBook?.furthestReadProgress,0.8)
        XCTAssertEqual(reader.bookNotesIndex.visibleNotes(through:reader.noteVisibilityProgress).count,1)
        reader.save()
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        reopened.currentID = id
        XCTAssertEqual(reopened.noteVisibilityProgress,0.8)
        var legacy = reopened.books[0]; legacy.furthestReadProgress = nil
        reopened.books = [legacy]
        XCTAssertEqual(reopened.noteVisibilityProgress,0.75)
    }
}

extension LibraryNotesTests {
    func testMergedInkExportIncludesEveryPartAndRemainsSearchable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:16,bitsPerPixel:32))
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let store=ReaderPageNoteStore(libraryDirectory:root)
        let a=try store.save(.init(drawing:Data([1]),page:png,ink:png,preview:png)),b=try store.save(.init(drawing:Data([2]),page:png,ink:png,preview:png))
        let anchor=ReaderPageAnchor(locator:"source",chapter:"第一章",progress:0,referenceX:0,referenceY:0,viewportWidth:100,viewportHeight:100,layoutKey:"test")
        func part(_ asset: UUID,_ text: String) -> ReaderInkPart {
            .init(id:UUID(),canvasID:UUID(),assetID:asset,anchor:anchor,bounds:.init(x:0,y:0,width:100,height:100),strokeIDs:[text],sources:[.init(id:text,block:text,offset:0,text:text,boxes:[.init(x:0,y:0,width:100,height:100)])])
        }
        var note=ReaderPageNote(assetID:a,anchor:anchor);note.parts=[part(a,"第一段原文"),part(b,"第二段原文")];note.text="手写旁的文字想法"
        let book=LibraryBook(id:UUID(),title:"书",author:"",filename:"",pageNotes:[note])
        let records=LibraryNotes.records(in:[book])
        XCTAssertEqual(LibraryNotes.filtered(records,query:"第二段原文").count,1)
        XCTAssertEqual(Set(try XCTUnwrap(records.first).inkAssetIDs),[a,b])
        let target=root.appendingPathComponent("完整笔记.md")
        try NoteMarkdownExport.write(records,title:"完整笔记",to:target,libraryDirectory:root)
        let text=try String(contentsOf:target,encoding:.utf8)
        XCTAssertTrue(text.contains(a.uuidString));XCTAssertTrue(text.contains(b.uuidString));XCTAssertTrue(text.contains("手写旁的文字想法"))
        let archive=try NoteExportArchive.make(records,title:"完整笔记",libraryDirectory:root)
        XCTAssertNotNil(archive.range(of:Data((a.uuidString+".png").utf8)))
        XCTAssertNotNil(archive.range(of:Data((b.uuidString+".png").utf8)))
    }
}
