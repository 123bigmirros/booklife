import XCTest
import BookSlideCore
@testable import BookSlideMac

@MainActor final class ReaderDiscussionNoteTests: XCTestCase {
    func testSelectingAPersonShowsOneEntityAndKeepsItsSourceAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"源泉",author:"",filename:"")]; reader.currentID = bookID
        let source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"吉丁太太",chapter:"第一章",progress:0.2)
        let person = try XCTUnwrap(reader.recordSelectedEntity(name:source.quote,kind:.person,source:source,bookID:bookID))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.bookNotesIndex.entities.map(\.id),[person])
        XCTAssertTrue(reopened.bookNotesIndex.notes.filter(\.showsOnCanvas).isEmpty)
        let record = try XCTUnwrap(LibraryNotes.records(in:reopened.books).first)
        XCTAssertEqual(record.kind,"原文")
        XCTAssertEqual(record.note.quote,source.quote)
        XCTAssertEqual(record.note.locator,source.cfi)
        var thought = try XCTUnwrap(reopened.currentAnnotations.first); thought.note = "我对她的第一印象"
        XCTAssertTrue(reopened.saveGraphAnnotation(thought,bookID:bookID,relation:nil))
        XCTAssertEqual(reopened.bookNotesIndex.notes.filter(\.showsOnCanvas).map(\.id),[source.id])
        var reselection = source; reselection.id = UUID().uuidString
        XCTAssertEqual(reopened.recordSelectedEntity(name:source.quote,kind:.person,source:reselection,bookID:bookID),person)
        XCTAssertEqual(reopened.currentAnnotations.count,1)
        XCTAssertEqual(reopened.currentAnnotations.first?.note,thought.note)
    }

    func testSelectedNodesKeepTheirChosenTypeAndReuseOnlyMatchingTypes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        let source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"山门前，须先学会静心。",chapter:"山门前",progress:0.4,note:"我的理解")
        reader.books = [.init(id:bookID,title:"通用节点",author:"",filename:"",annotations:[source])]; reader.currentID = bookID
        var ids: [BookEntityKind:UUID] = [:]
        for kind in BookEntityKind.allCases {
            let id = try XCTUnwrap(reader.recordSelectedEntity(name:"静心",kind:kind,source:source,bookID:bookID))
            ids[kind] = id
            XCTAssertEqual(reader.recordSelectedEntity(name:"静心",kind:kind,source:source,bookID:bookID),id)
        }
        XCTAssertEqual(Set(ids.values).count,BookEntityKind.allCases.count)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        for entity in try XCTUnwrap(reopened.currentBook).graph.entities {
            XCTAssertEqual(entity.id,ids[entity.kind])
        }
        XCTAssertEqual(reopened.currentAnnotations.count,1)
        XCTAssertEqual(reopened.currentAnnotations.first?.entityIDs?.count,BookEntityKind.allCases.count)
        XCTAssertEqual(reopened.currentAnnotations.first?.note,source.note)
        XCTAssertEqual(reopened.currentAnnotations.first?.cfi,source.cfi)
    }
    func testSelectedPersonUsesCommonGraphCommitAndPreservesConversationAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        var source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"沈砚向林川行了弟子礼。",chapter:"山门前",progress:0.4,note:"动作中的转变")
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"这是什么心态？"),.init(role:.assistant,text:"尊重与克制。[原文]")]; source.discussion = discussion
        reader.books = [.init(id:bookID,title:"选文记录",author:"",filename:"",annotations:[source])]; reader.currentID = bookID
        let person = try XCTUnwrap(reader.recordSelectedEntity(name:"沈砚",kind:.person,source:source,bookID:bookID))
        let edge = ReadingEdge(kind:.association,source:.init(.discussion,source.id),target:.init(.entity,person.uuidString),label:"解读人物")
        XCTAssertTrue(reader.performReadingMutation(.connect(edge)))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.currentAnnotations.first?.discussion,discussion)
        XCTAssertEqual(reopened.currentAnnotations.first?.note,source.note)
        XCTAssertEqual(reopened.currentAnnotations.first?.entityIDs,[person])
        XCTAssertTrue(reopened.currentBook?.graph.edges.contains(edge) == true)
        let before = reader.books[0].graph
        XCTAssertNil(reader.recordSelectedEntity(name:"林川",kind:.person,source:source,bookID:UUID()))
        XCTAssertEqual(reader.books[0].graph,before)
    }
    func testFailedSelectedPersonCommitPublishesNeitherPersonNorSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"写入失败",author:"",filename:"")]; reader.currentID = bookID
        try? FileManager.default.removeItem(at:root)
        try Data("blocking-file".utf8).write(to:root)
        let source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"沈砚向林川行了弟子礼。",chapter:"山门前",progress:0.4)
        XCTAssertNil(reader.recordSelectedEntity(name:"林川",kind:.person,source:source,bookID:bookID))
        XCTAssertTrue(reader.currentBook?.graph.nodes.isEmpty == true)
    }
    func testSelectionOpensDiscussionOnExistingNoteAndRejectsStaleBookSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        var note = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2,/1:0,/1:8)",quote:"选中的原文",chapter:"第一章",progress:0.2,note:"我的想法")
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"原来的问题")]; note.discussion = discussion
        reader.books = [LibraryBook(id:bookID,title:"测试书",author:"测试",filename:"",annotations:[note])]; reader.currentID = bookID
        var context: [String:Any] = ["session":UUID().uuidString,"id":note.id,"cfi":note.cfi,"quote":note.quote,"chapter":note.chapter,"progress":note.progress,"color":"yellow"]
        reader.receiveAnnotation("annotationDiscuss",value:context)
        XCTAssertNil(reader.annotationDraft)
        context["session"] = reader.annotationSessionID.uuidString
        reader.receiveAnnotation("annotationDiscuss",value:context)
        XCTAssertEqual(reader.selectionDiscussion?.annotation.note,"我的想法")
        XCTAssertEqual(reader.selectionDiscussion?.annotation.discussion,discussion)
        XCTAssertNil(reader.annotationDraft)
        XCTAssertNil(reader.discussionNoteID)
        XCTAssertFalse(reader.showNoteGraph,"Selected text goes directly to the independent discussion module")
    }
    func testFreshSelectionDoesNotRequireANoteAndReselectionKeepsItsConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"选文讨论",author:"测试",filename:"")]; reader.currentID = bookID
        let cfi = "epubcfi(/6/2!/4/2,/1:0,/1:8)"
        var context: [String:Any] = ["session":reader.annotationSessionID.uuidString,"id":UUID().uuidString,"cfi":cfi,"quote":"选中即可讨论的原文","chapter":"第一章","progress":0.2,"color":"yellow"]
        reader.receiveAnnotation("annotationDiscuss",value:context)
        var selected = try XCTUnwrap(reader.selectionDiscussion?.annotation)
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        XCTAssertTrue(reader.autosaveDiscussion(selected,bookID:bookID))
        XCTAssertTrue(reader.currentAnnotations.isEmpty,"Opening and closing without a question must not create a phantom note or highlight")
        var discussion = ReaderDiscussion(); discussion.composer = "这句话是什么意思？"; selected.discussion = discussion
        XCTAssertTrue(reader.autosaveDiscussion(selected,bookID:bookID))
        XCTAssertEqual(reader.currentAnnotations.first?.note,"")
        XCTAssertEqual(reader.currentAnnotations.first?.discussion?.composer,discussion.composer)
        context["id"] = UUID().uuidString
        reader.selectionDiscussion = nil; reader.receiveAnnotation("annotationDiscuss",value:context)
        XCTAssertEqual(reader.selectionDiscussion?.id,selected.id)
        XCTAssertEqual(reader.selectionDiscussion?.annotation.discussion,discussion,"A new native selection ID for the same CFI must reuse the saved conversation")
        XCTAssertEqual(reader.currentAnnotations.count,1)
        var recovered = ReaderAnnotation(cfi:"epubcfi(/6/4!/4/2,/1:0,/1:8)",quote:"未写入索引的选文",chapter:"第二章",progress:0.3)
        recovered.discussion = discussion
        try reader.keepTextDraft(recovered,bookID:bookID)
        context["id"] = UUID().uuidString; context["cfi"] = recovered.cfi; context["quote"] = recovered.quote
        reader.receiveAnnotation("annotationDiscuss",value:context)
        XCTAssertEqual(reader.selectionDiscussion?.id,recovered.id)
        XCTAssertEqual(reader.selectionDiscussion?.annotation.discussion?.composer,discussion.composer,"Reselecting also recovers an unsent question retained after an index write failure")
        recovered.discussion?.composer = ""
        XCTAssertTrue(reader.autosaveDiscussion(recovered,bookID:bookID))
        XCTAssertTrue(try reader.noteDraftStore.textDrafts(bookID:bookID).isEmpty,"Clearing a new unsent question must not leave a stale recovery draft")
    }
    func testBookAndChapterUseTheExistingDiscussionNodesAndPersistInTheirBranches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        let chapter = ChapterItem(id:"toc/0",href:"one.xhtml",title:"第一章",depth:0)
        reader.books = [LibraryBook(id:bookID,title:"阅读测试",author:"",filename:"")]
        reader.currentID = bookID
        reader.chapters = [chapter]

        let bookThread = try XCTUnwrap(reader.beginReadingNodeDiscussion(chapter:nil))
        var record = try XCTUnwrap(reader.currentAnnotations.first { $0.id == bookThread.owner })
        record.discussion?.messages = [.init(role:.user,text:"梳理已读主线")]
        XCTAssertTrue(reader.autosaveDiscussion(record,bookID:bookID))
        let chapterThread = try XCTUnwrap(reader.beginReadingNodeDiscussion(chapter:chapter))
        XCTAssertNotEqual(bookThread,chapterThread)
        XCTAssertEqual(reader.beginReadingNodeDiscussion(chapter:nil),bookThread)
        XCTAssertEqual(reader.selectedReadingItem,.node(bookThread))
        XCTAssertEqual(reader.currentAnnotations.count,2)

        let document = reader.mindMapDocument()
        let rows = try document.flattened()
        let chapterTopic = try XCTUnwrap(rows.first { $0.topic.metadata?.kind == "chapter" })
        XCTAssertEqual(document.topic(containing:bookThread)?.id,document.nodeData.id)
        XCTAssertEqual(document.topic(containing:chapterThread)?.id,chapterTopic.topic.id)
        XCTAssertFalse(rows.contains { $0.topic.metadata?.nodeID == bookThread || $0.topic.metadata?.nodeID == chapterThread })
        XCTAssertFalse(rows.contains { $0.topic.metadata?.nodeID == .init(.note,bookThread.owner) })
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        reopened.currentID = bookID
        reopened.chapters = [chapter]
        XCTAssertEqual(reopened.beginReadingNodeDiscussion(chapter:nil),bookThread)
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == bookThread.owner }?.discussion?.messages.first?.text,"梳理已读主线")
        XCTAssertEqual(reopened.searchReadingGraph("梳理已读主线").first { $0.kind == .message }?.item,
            .node(.init(.message,bookThread.owner,local:record.discussion?.messages.first?.id.uuidString)))
    }

    func testConversationSurvivesCommitReopenDeleteRestoreSearchAndMarkdownExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试书",author:"测试",filename:"")]; reader.currentID = bookID
        var note = ReaderAnnotation(cfi:"",quote:"原文依据",chapter:"第一章",progress:0.2,note:"我的独立思考")
        var discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"为什么信息越多反而难判断？"),.init(role:.assistant,text:"注意力也有成本。[原文]",model:"本地 Codex")]
        note.discussion = discussion
        try reader.keepTextDraft(note,bookID:bookID)
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        XCTAssertTrue(reader.textNoteDrafts.isEmpty)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.currentAnnotations.first?.discussion,discussion)
        XCTAssertEqual(reopened.currentAnnotations.first?.note,"我的独立思考")
        let records = LibraryNotes.filtered(LibraryNotes.records(in:reopened.books),query:"注意力")
        XCTAssertEqual(records.count,1)
        let markdown = NoteMarkdownExport.render(records,title:"测试导出")
        for text in ["测试书","原文依据","我的独立思考","为什么信息","注意力也有成本","本地 Codex"] { XCTAssertTrue(markdown.contains(text),text) }
        XCTAssertTrue(reopened.removeAnnotation(note.id,bookID:bookID))
        let removed = try XCTUnwrap(reopened.removedNotes.first)
        XCTAssertEqual(removed.annotation?.discussion,discussion)
        XCTAssertTrue(reopened.restoreRemovedNote(removed.id))
        XCTAssertEqual(reopened.currentAnnotations.first?.discussion,discussion)
    }
}
