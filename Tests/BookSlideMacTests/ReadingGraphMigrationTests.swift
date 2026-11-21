import XCTest
import BookSlideCore
@testable import BookSlideMac

@MainActor final class ReadingGraphMigrationTests: XCTestCase {
    func testLegacyLibraryMigratesOnceWithoutLosingIDsHistoryDraftsOrInk() throws {
        let bookID = UUID(), person = BookEntity(name:"旧书库人物",kind:.person,aliases:["旧别名"])
        var note = ReaderAnnotation(cfi:"old-cfi",quote:"旧原文",chapter:"第一章",progress:0.5,note:"旧笔记")
        note.entityIDs = [person.id]
        var discussion = ReaderDiscussion(); discussion.composer = "未发送的问题"
        var answer = ReaderDiscussionMessage(role:.assistant,text:"未完成的回答",state:.interrupted,model:"旧模型")
        answer.context = .init(sources:[.init(id:"原文",label:"第一章",text:"当时的引用",limit:100)])
        discussion.messages = [.init(role:.user,text:"旧问题"),answer]; note.discussion = discussion
        let ink = ReaderPageNote(assetID:UUID(),anchor:.init(locator:"ink",chapter:"第一章",progress:0.5,referenceX:0,referenceY:0,viewportWidth:800,viewportHeight:600,layoutKey:"old-layout"))
        let removed = ReaderRemovedNote(annotation:note,noteOnly:true), draft = BookRelationDraft(label:"未完成关系")
        var personJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(person)) as? [String:Any])
        personJSON["deletedAt"] = Date().timeIntervalSinceReferenceDate
        let legacy: [String:Any] = ["id":bookID.uuidString,"title":"旧书库","author":"作者","filename":"old.epub","locator":"old-locator","progress":0.5,"lastRead":12345,
            "annotations":try JSONSerialization.jsonObject(with:JSONEncoder().encode([note])),
            "pageNotes":try JSONSerialization.jsonObject(with:JSONEncoder().encode([ink])),
            "knowledgeEntities":[personJSON],"knowledgeRelations":[],
            "removedNotes":try JSONSerialization.jsonObject(with:JSONEncoder().encode([removed])),
            "relationDrafts":try JSONSerialization.jsonObject(with:JSONEncoder().encode([draft])),"sourcePath":"/fixture/book.epub","hidden":true]
        let bytes = try JSONSerialization.data(withJSONObject:legacy)
        let book = try JSONDecoder().decode(LibraryBook.self,from:bytes)
        XCTAssertEqual(book.id,bookID); XCTAssertEqual(book.annotations,[note]); XCTAssertEqual(book.pageNotes,[ink])
        XCTAssertNotNil(book.knowledgeEntities?.first?.deletedAt); XCTAssertEqual(book.removedNotes,[removed]); XCTAssertEqual(book.relationDrafts,[draft])
        XCTAssertEqual(book.locator,"old-locator"); XCTAssertEqual(book.sourcePath,"/fixture/book.epub"); XCTAssertEqual(book.hidden,true)
        let encoded = try JSONEncoder().encode(book), root = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNotNil(root["graph"])
        for legacyKey in ["annotations","pageNotes","knowledgeEntities","knowledgeRelations","removedNotes","relationDrafts"] { XCTAssertNil(root[legacyKey],"Only the graph is authoritative on disk") }
        let reopened = try JSONDecoder().decode(LibraryBook.self,from:encoded)
        XCTAssertEqual(reopened.graph,book.graph); XCTAssertEqual(reopened.annotations,[note]); XCTAssertEqual(reopened.pageNotes,[ink])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let oldIndex = try JSONSerialization.data(withJSONObject:[legacy])
        try oldIndex.write(to:directory.appendingPathComponent("library.json"))
        let store = LibraryIndexStore(directory:directory)
        try store.save(try XCTUnwrap(store.load([LibraryBook].self)?.value))
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("library.backup.json")),oldIndex,"The first graph write retains the original readable legacy index as its backup")
    }
    func testExistingEditorsWriteThroughToOneGraphAndFreshReadersSeeChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), id = UUID()
        reader.books = [.init(id:id,title:"统一处理",author:"",filename:"")]; reader.currentID = id
        let person = try XCTUnwrap(reader.saveKnowledgeEntity(.init(name:"林川",kind:.person)))
        var note = ReaderAnnotation(cfi:"",quote:"原文",chapter:"第一章",progress:0.2,note:"我的理解"); note.entityIDs = [person]
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"我的提问"),.init(role:.assistant,text:"AI 的回答",model:"测试")]; note.discussion = discussion
        XCTAssertTrue(reader.autosaveGraphAnnotation(note,bookID:id,relation:nil))
        let saved = try XCTUnwrap(LibraryIndexStore(directory:root).load([LibraryBook].self)?.value.first)
        XCTAssertEqual(saved.annotations?.first?.discussion,discussion)
        XCTAssertEqual(saved.graph.search("AI 的回答").first?.id.kind,.message)
        XCTAssertEqual(saved.graph.search("林川").first?.id.kind,.entity)
        XCTAssertTrue(reader.removeAnnotation(note.id,bookID:id)); XCTAssertTrue(reader.currentAnnotations.isEmpty)
        XCTAssertTrue(reader.restoreRemovedNote(try XCTUnwrap(reader.noteUndoID)))
        XCTAssertEqual(reader.currentAnnotations.first?.discussion,discussion)
        XCTAssertTrue(reader.setKnowledgeEntityDeleted(person,deleted:true))
        XCTAssertEqual(reader.currentAnnotations.first?.entityIDs,[person],"Recoverable links survive a person being removed")
        XCTAssertTrue(reader.setKnowledgeEntityDeleted(person,deleted:false))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = id
        XCTAssertEqual(reopened.currentAnnotations.first?.discussion,discussion); XCTAssertEqual(reopened.currentAnnotations.first?.entityIDs,[person])
    }
    func testCommonSearchSelectionAndCrossTypeConnectionsSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), id = UUID()
        reader.books = [.init(id:id,title:"节点搜索",author:"",filename:"")]; reader.currentID = id
        let person = try XCTUnwrap(reader.saveKnowledgeEntity(.init(name:"林川",kind:.person)))
        var note = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.2,note:"自己的想法")
        let answer = ReaderDiscussionMessage(role:.assistant,text:"可以先保留问题",model:"测试")
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"如何阅读"),answer]; note.discussion = discussion
        XCTAssertTrue(reader.autosaveGraphAnnotation(note,bookID:id,relation:nil))
        let thread = ReadingNodeID(.discussion,note.id), personID = ReadingNodeID(.entity,person.uuidString)
        let edge = ReadingEdge(kind:.association,source:thread,target:personID,label:"理解人物",record:UUID())
        XCTAssertTrue(reader.performReadingMutation(.connect(edge)))
        let message = try XCTUnwrap(reader.searchReadingGraph("可以先保留问题").first { $0.kind == .message })
        reader.selectReadingItem(message.item)
        XCTAssertEqual(reader.discussionNoteID,note.id); XCTAssertEqual(reader.discussionFocusMessage,answer.id)
        XCTAssertTrue(reader.searchReadingGraph("理解人物").contains { $0.item == .edge(edge.id) })
        reader.selectReadingItem(.edge(edge.id))
        XCTAssertTrue(reader.performReadingMutation(.remove(personID)))
        XCTAssertNil(reader.selectedReadingItem,"Removed endpoints must clear stale edge selection")
        XCTAssertTrue(reader.performReadingMutation(.restore(personID)))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = id
        XCTAssertTrue(reopened.currentBook?.graph.edges.contains(edge) == true)
        XCTAssertTrue(reopened.searchReadingGraph("可以先保留问题").contains { $0.kind == .message })
        reopened.selectReadingItem(.edge(edge.id))
        XCTAssertTrue(reopened.commitReadingGraph(bookID:id) { $0.replaceEntities([]) })
        XCTAssertNil(reopened.selectedReadingItem,"A physically missing endpoint must also clear the selected connection")
    }
    func testFutureSchemaNeverFallsBackToOlderBackupOrOverwritesTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryIndexStore(directory:root)
        let books = [LibraryBook(id:UUID(),title:"新版本书库",author:"",filename:"")]
        try store.save(books)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(books)) as? [[String:Any]])
        var graph = try XCTUnwrap(json[0]["graph"] as? [String:Any]); graph["version"] = 999; json[0]["graph"] = graph
        let future = try JSONSerialization.data(withJSONObject:json), url = root.appendingPathComponent("library.json")
        try future.write(to:url)
        XCTAssertThrowsError(try store.load([LibraryBook].self))
        let reader = ReaderModel(directory:root,loadExternalSources:false)
        XCTAssertFalse(reader.allowsLibraryWrites); reader.save()
        XCTAssertEqual(try Data(contentsOf:url),future)
    }
}
