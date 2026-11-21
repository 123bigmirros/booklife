import XCTest
import SwiftUI
import AppKit
import BookSlideCore
@testable import BookSlideMac

@MainActor final class BookKnowledgeModelTests: XCTestCase {
    func testEventCreatesBothEndpointsAndAnEdgeInOneSaveAndSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"事件",author:"",filename:"",progress:0.3)]; reader.currentID = bookID
        let a = BookEntity(name:"林川",kind:.person), b = BookEntity(name:"书院",kind:.organization)
        let edge = try XCTUnwrap(reader.saveReadingEvent(source:a,target:b,action:" 加入 ",note:"在第三章加入书院",bookID:bookID))
        XCTAssertEqual(reader.currentBook?.graph.entities.count,2)
        XCTAssertEqual(reader.currentBook?.graph.node(edge.source)?.title,"林川")
        XCTAssertEqual(reader.currentBook?.graph.node(edge.target)?.title,"书院")
        XCTAssertEqual(reader.currentBook?.graph.relations.first?.label,"加入")
        let note = try XCTUnwrap(reader.currentAnnotations.first)
        XCTAssertEqual(Set(note.entityIDs ?? []),[a.id,b.id])
        XCTAssertEqual(reader.currentBook?.graph.relations.first?.evidenceIDs,[note.id])
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertTrue(reopened.currentBook?.graph.edges.contains(where:{ $0.id == edge }) == true)
        XCTAssertEqual(reopened.currentAnnotations.first?.note,"在第三章加入书院")
        XCTAssertEqual(reopened.saveReadingEvent(source:BookEntity(name:"林川",kind:.person),target:BookEntity(name:"书院",kind:.organization),action:"加入",note:"在第三章加入书院",bookID:bookID),edge)
        XCTAssertEqual(reopened.currentBook?.graph.entities.count,2)
        XCTAssertEqual(reopened.currentBook?.graph.relations.count,1)
        XCTAssertEqual(reopened.currentAnnotations.count,1)
    }
    func testEventReusesAliasesAndNeedsNoNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"事件",author:"",filename:"")]; reader.currentID = bookID
        let existing = try XCTUnwrap(reader.saveKnowledgeEntity(.init(name:"云山书院",kind:.organization,aliases:["书院"])))
        let edge = try XCTUnwrap(reader.saveReadingEvent(source:.init(name:"林川",kind:.person),target:.init(name:"书院",kind:.organization),action:"加入",note:"",bookID:bookID))
        XCTAssertEqual(edge.target,.init(.entity,existing.uuidString))
        XCTAssertEqual(reader.currentBook?.graph.entities.count,2)
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
    }
    func testEventConnectsAnExistingNoteToANewNodeAndKeepsItsEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"事件",author:"",filename:"")]; reader.currentID = bookID
        var note = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.2,note:"这里提出的问题")
        note.title = "疑问"
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        let sourceID = ReadingNodeID(.note,note.id), target = BookEntity(name:"林川",kind:.person)
        let edge = try XCTUnwrap(reader.saveReadingEvent(source:.init(name:"疑问",kind:.other),target:target,action:"涉及",note:"和人物动机有关",sourceNode:sourceID,bookID:bookID))
        XCTAssertEqual(edge.source,sourceID)
        XCTAssertEqual(edge.target,.init(.entity,target.id.uuidString))
        XCTAssertEqual(reader.currentBook?.graph.entities.count,1,"Selecting a note must not invent an entity copy")
        XCTAssertEqual(reader.currentAnnotations.count,2)
        let evidence = try XCTUnwrap(reader.currentAnnotations.first { $0.id != note.id })
        for targetID in [edge.source,edge.target] {
            XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains { $0.id.source == .init(.note,evidence.id) && $0.id.target == targetID && $0.label == "事件依据" } == true)
        }
        XCTAssertEqual(reader.saveReadingEvent(source:.init(name:"疑问",kind:.other),target:target,action:"涉及",note:"和人物动机有关",sourceNode:sourceID,bookID:bookID),edge)
        XCTAssertEqual(reader.currentAnnotations.count,2)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertTrue(reopened.currentBook?.graph.edges.contains { $0.id == edge } == true)
        let before = reader.currentBook?.graph
        XCTAssertNil(reader.saveReadingEvent(source:.init(name:"失效笔记",kind:.other),target:.init(name:"乙",kind:.person),action:"涉及",note:"",sourceNode:.init(.note,UUID().uuidString),bookID:bookID))
        XCTAssertEqual(reader.currentBook?.graph,before)
    }
    func testInvalidOrFailedEventLeavesNoPartialNodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"事件",author:"",filename:"")]; reader.currentID = bookID
        let a = BookEntity(name:"甲",kind:.person), b = BookEntity(name:"乙",kind:.person)
        XCTAssertNil(reader.saveReadingEvent(source:a,target:b,action:"",note:"",bookID:bookID))
        XCTAssertNil(reader.saveReadingEvent(source:a,target:.init(name:"甲",kind:.person),action:"帮助",note:"",bookID:bookID))
        XCTAssertNil(reader.saveReadingEvent(source:a,target:b,action:"帮助",note:"",bookID:UUID()))
        XCTAssertTrue(reader.currentBook?.graph.nodes.isEmpty == true)
        try? FileManager.default.removeItem(at:root)
        try Data("blocking-file".utf8).write(to:root)
        XCTAssertNil(reader.saveReadingEvent(source:a,target:b,action:"帮助",note:"事件笔记",bookID:bookID))
        XCTAssertTrue(reader.currentBook?.graph.nodes.isEmpty == true)
        XCTAssertTrue(reader.currentBook?.graph.edges.isEmpty == true)
    }
    func testLegacyAddNodeActionOpensTheSharedNoteEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [.init(id:bookID,title:"节点笔记",author:"",filename:"")]; reader.currentID = bookID
        let id = UUID().uuidString
        reader.receiveAnnotation("annotationEntity",value:["session":reader.annotationSessionID.uuidString,"id":id,"cfi":"epubcfi(/6/2!/4/2)","quote":"原文","chapter":"第一章","progress":0.2,"color":"yellow"])
        XCTAssertNil(reader.selectionEntity)
        XCTAssertEqual(reader.annotationDraft?.id,id)
        XCTAssertEqual(reader.graphNoteID,id)
        XCTAssertTrue(reader.showNoteGraph)
    }
    func testMergedSelectionEntryPreservesSavedNoteAndRecoveredDraftAtTheSameRange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        let note = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"原文",chapter:"第一章",progress:0.2,note:"已经保存的想法")
        reader.books = [.init(id:bookID,title:"节点笔记",author:"",filename:"",annotations:[note])]; reader.currentID = bookID
        let payload: [String:Any] = ["session":reader.annotationSessionID.uuidString,"id":UUID().uuidString,"cfi":note.cfi,"quote":note.quote,"chapter":note.chapter,"progress":note.progress,"color":"yellow"]
        reader.receiveAnnotation("annotationEntity",value:payload)
        XCTAssertEqual(reader.annotationDraft?.id,note.id)
        XCTAssertEqual(reader.annotationDraft?.annotation.note,"已经保存的想法")
        var draft = note; draft.note = "尚未保存的新想法"
        try reader.keepTextDraft(draft,bookID:bookID)
        reader.receiveAnnotation("annotationEdit",value:payload)
        XCTAssertEqual(reader.annotationDraft?.annotation.note,"尚未保存的新想法")
    }
    func testRelationEvidenceRejectsUnsavedDraftAndSurvivesEditingWhileItsNoteIsDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"关系依据",author:"",filename:"")]; reader.currentID = bookID
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"甲",kind:.person)))
        let b = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"乙",kind:.person)))
        let note = ReaderAnnotation(cfi:"",quote:"甲指导乙",chapter:"第一章",progress:0,note:"师徒关系的依据")
        try reader.keepTextDraft(note,bookID:bookID)
        var relation = BookRelation(sourceID:a,targetID:b,label:"指导",evidenceIDs:[note.id])
        XCTAssertNil(reader.saveIndependentRelation(relation),"A selected draft must not silently disappear from the relation")
        XCTAssertTrue(reader.currentBook?.knowledgeRelations?.isEmpty ?? true)
        XCTAssertEqual(reader.textNoteDrafts.first?.annotation,note)
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        XCTAssertNotNil(reader.saveIndependentRelation(relation))
        XCTAssertTrue(reader.removeAnnotation(note.id,bookID:bookID))
        let removedID = try XCTUnwrap(reader.noteUndoID)
        relation.label = "是师父"
        XCTAssertNotNil(reader.saveIndependentRelation(relation))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.currentBook?.knowledgeRelations?.first?.evidenceIDs,[note.id])
        XCTAssertTrue(reopened.restoreRemovedNote(removedID))
        XCTAssertEqual(reopened.currentBook?.knowledgeRelations?.first?.evidenceIDs,[reopened.currentAnnotations[0].id])
    }
    func testIndependentThingRelationsKeepIdentityAndSurviveAddingAndRemovingEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"事物与关系",author:"",filename:"",progress:0.4)]; reader.currentID = bookID
        let person = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"林川",kind:.person)))
        let organization = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"云山书院",kind:.organization,aliases:["书院"])))
        let place = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"临江",kind:.place)))
        let item = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"手札",kind:.object)))
        let event = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"论学",kind:.event)))
        let idea = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"知行合一",kind:.concept)))
        let other = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"待分类",kind:.other)))
        let joins = try XCTUnwrap(reader.saveIndependentRelation(BookRelation(sourceID:person,targetID:organization,label:"加入",evidenceIDs:[])))
        for (a,label,b) in [(organization,"位于",place),(person,"拥有",item),(person,"参与",event),(event,"讨论",idea),(other,"属于",organization)] {
            XCTAssertNotNil(reader.saveIndependentRelation(BookRelation(sourceID:a,targetID:b,label:label,evidenceIDs:[])))
        }
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        XCTAssertEqual(reader.saveKnowledgeEntity(BookEntity(name:"书院",kind:.organization)),organization)
        var recategorized = try XCTUnwrap(reader.currentBook?.knowledgeEntities?.first { $0.id == other })
        recategorized.kind = .object
        XCTAssertEqual(reader.saveKnowledgeEntity(recategorized),other)
        var note = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.4,note:"书院的记载")
        note.entityIDs = [person,organization]
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        var relation = try XCTUnwrap(reader.currentBook?.knowledgeRelations?.first { $0.id == joins })
        relation.evidenceIDs = [note.id]
        XCTAssertEqual(reader.saveIndependentRelation(relation),joins)
        XCTAssertTrue(reader.removeAnnotation(note.id,bookID:bookID))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.bookNotesIndex.relations.count,6)
        XCTAssertEqual(reopened.bookNotesIndex.entities.first { $0.id == other }?.kind,.object)
        XCTAssertEqual(reopened.bookNotesIndex.matchingRelations("书院",through:1).count,3)
        // Soft deletion keeps the evidence link available for undo while the
        // relation remains independently visible with no live source notes.
        XCTAssertEqual(reopened.bookNotesIndex.relations.first { $0.id == joins }?.evidenceIDs,[note.id])
        XCTAssertTrue(reopened.bookNotesIndex.visibleNotes(through:1).isEmpty)
        XCTAssertTrue(reopened.currentAnnotations.isEmpty)
    }
    func testExternalBookOutlineReachesNativeModelAndGraph() async throws {
        guard let path = ProcessInfo.processInfo.environment["BOOKSLIDE_OUTLINE_EPUB"] else { throw XCTSkip("Set BOOKSLIDE_OUTLINE_EPUB for an external-book integration check") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false), id = UUID()
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = reader.webView; window.orderFront(nil)
        defer { reader.close(); window.close(); try? FileManager.default.removeItem(at:root) }
        reader.books = [LibraryBook(id:id,title:"外部 EPUB 检查",author:"",filename:"",sourcePath:path)]
        reader.open(id)
        for _ in 0..<200 {
            if !reader.loading, reader.position != nil { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertFalse(reader.loading,reader.error ?? "Book did not finish loading")
        let outline = try await reader.webView.callAsyncJavaScript("return await reader.outline()",arguments:[:],in:nil,contentWorld:.page) as? [[String:Any]] ?? []
        try await Task.sleep(for:.milliseconds(150))
        print("NATIVE_OUTLINE_COUNTS javascript=\(outline.count) native=\(reader.chapters.count) nested=\(reader.chapters.filter { $0.depth > 0 }.count)")
        XCTAssertFalse(outline.isEmpty)
        XCTAssertEqual(reader.chapters.count,outline.count)
        XCTAssertTrue(reader.chapters.contains { $0.id.hasPrefix("heading-") })
        let structure = reader.bookNotesIndex.structure
        print("NATIVE_STRUCTURE_COUNTS roots=\(structure.roots.count) descendants=\(structure.nodes.filter { $0.parent != nil }.count)")
        if let parent = structure.nodes.first(where: { $0.entry.title.hasPrefix("第一章") && !$0.children.isEmpty }) {
            reader.go(parent.entry.href)
            for _ in 0..<100 {
                if !reader.busy { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            reader.showNoteGraph = true
            let host = NSHostingView(rootView:BookNotesWorkspace(reader:reader,close:{}).frame(width:1200,height:800))
            window.contentView = host
            try await Task.sleep(for:.milliseconds(400)); host.layoutSubtreeIfNeeded()
            if let output = ProcessInfo.processInfo.environment["BOOKSLIDE_OUTLINE_CAPTURE_DIR"], let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                host.cacheDisplay(in:host.bounds,to:rep)
                try rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("native-book-outline.png"))
            }
        }
    }
    func testAutomaticPencilHighlightPreservesExistingNotesAndUnfinishedDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        var saved = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2,/1:0,/1:2)",quote:"原文",chapter:"第一章",progress:0.2,color:.blue,note:"原来的笔记")
        saved.title = "保留的标题"
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"",annotations:[saved])]; reader.currentID = bookID
        reader.save()
        var draft = saved; draft.note = "正在修改，尚未提交"
        try reader.keepTextDraft(draft,bookID:bookID)
        let payload: [String:Any] = ["session":reader.annotationSessionID.uuidString,"id":UUID().uuidString,"cfi":saved.cfi,"quote":saved.quote,"chapter":saved.chapter,"progress":saved.progress,"color":"yellow","x":40.0,"y":60.0]
        reader.receiveAnnotation("annotationPencilHighlight",value:payload)
        XCTAssertEqual(reader.currentAnnotations,[saved])
        XCTAssertEqual(reader.textNoteDrafts.first?.annotation,draft)
        XCTAssertEqual(try reader.noteDraftStore.textDrafts(bookID:bookID).count,1)
    }
    func testAutomaticPencilHighlightCommitsOnceAndRejectsStaleSessionsAndFailedWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID; reader.save()
        var payload: [String:Any] = ["session":UUID().uuidString,"id":UUID().uuidString,"cfi":"epubcfi(/6/2!/4/2,/1:0,/1:2)","quote":"原文","chapter":"第一章","progress":0.2,"color":"yellow","x":40.0,"y":60.0]
        reader.receiveAnnotation("annotationPencilHighlight",value:payload)
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        payload["session"] = reader.annotationSessionID.uuidString
        let moved = root.appendingPathExtension("test-backup")
        try FileManager.default.moveItem(at:root,to:moved)
        defer { try? FileManager.default.removeItem(at:root); try? FileManager.default.moveItem(at:moved,to:root) }
        try Data([0]).write(to:root)
        reader.receiveAnnotation("annotationPencilHighlight",value:payload)
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        XCTAssertNotNil(reader.error)
        try FileManager.default.removeItem(at:root); try FileManager.default.moveItem(at:moved,to:root)
        reader.receiveAnnotation("annotationPencilHighlight",value:payload)
        reader.receiveAnnotation("annotationPencilHighlight",value:payload)
        XCTAssertEqual(reader.currentAnnotations.count,1)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.currentAnnotations.first?.quote,"原文")
    }
    func testMacGraphViewportPreservesPanAndBoundsAcrossContentUpdates() async throws {
        let request = UUID(), size = CGSize(width:1000,height:2400)
        func viewport(_ title: String) -> BookGraphViewport<some View> {
            BookGraphViewport(content:Text(title).frame(width:size.width,height:size.height),canvasSize:size,scale:1,focus:CGPoint(x:100,y:100),focusRequest:request)
        }
        let host = NSHostingView(rootView:viewport("第一章与小标题"))
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> NSScrollView? {
            if let view = view as? BookGraphMacScrollView { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        try await Task.sleep(for:.milliseconds(250)); host.layoutSubtreeIfNeeded()
        let graph = try XCTUnwrap(find(host))
        XCTAssertTrue(graph.hasHorizontalScroller && graph.hasVerticalScroller)
        XCTAssertTrue(graph.gestureRecognizers.contains { $0 is NSPanGestureRecognizer })
        graph.contentView.scroll(to:CGPoint(x:180,y:700)); graph.reflectScrolledClipView(graph.contentView)
        host.rootView = viewport("修改笔记后的内容")
        try await Task.sleep(for:.milliseconds(150)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(graph.contentView.bounds.origin.x,180,accuracy:1)
        XCTAssertEqual(graph.contentView.bounds.origin.y,700,accuracy:1)
        XCTAssertEqual(BookGraphViewportPosition.clamp(CGPoint(x:-50,y:5000),canvas:size,viewport:CGSize(width:600,height:400)),CGPoint(x:0,y:2000))
    }
    func testQuickEditorRecoversConnectionsCommitsEvidenceAndReopensTheSameNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"林川",kind:.person,aliases:["青川客"])))
        let b = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"沈砚",kind:.person)))
        let original = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2,/1:0,/1:2)",quote:"青川客授业",chapter:"第一章",progress:0.3)
        var edited = reader.noteForEditing(original,bookID:bookID)
        edited.note = "师徒关系的依据"; edited.entityIDs = [a,b]
        edited.graphRelationDraft = BookRelation(sourceID:a,targetID:b,label:"师父",evidenceIDs:[edited.id])
        try reader.keepTextDraft(edited,bookID:bookID)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        reopened.loadNoteDrafts(bookID:bookID)
        let recovered = reopened.noteForEditing(original,bookID:bookID)
        XCTAssertEqual(recovered,edited)
        XCTAssertTrue(reopened.currentAnnotations.isEmpty,"An autosaved draft must not commit content or evidence.")
        XCTAssertTrue(reopened.saveGraphAnnotation(recovered,bookID:bookID,relation:recovered.graphRelationDraft))
        XCTAssertTrue(reopened.textNoteDrafts.isEmpty)
        XCTAssertEqual(reopened.bookNotesIndex.search("青川客").map(\.id),[edited.id])
        XCTAssertEqual(reopened.bookNotesIndex.relations.first?.evidenceIDs,[edited.id])
        let committed = try XCTUnwrap(reopened.currentAnnotations.first)
        XCTAssertNil(committed.graphRelationDraft)
        var again = reopened.noteForEditing(committed,bookID:bookID)
        XCTAssertEqual(again.graphRelationDraft?.label,"师父")
        again.graphRelationDraft?.label = "传授武艺"
        XCTAssertTrue(reopened.saveGraphAnnotation(again,bookID:bookID,relation:again.graphRelationDraft))
        XCTAssertEqual(reopened.currentAnnotations.count,1)
        XCTAssertEqual(reopened.bookNotesIndex.relations.count,1)
        XCTAssertEqual(reopened.bookNotesIndex.relations.first?.label,"传授武艺")
        again.graphRelationDraft = nil
        again.note = "未完成的再次修改"
        try reopened.keepTextDraft(again,bookID:bookID)
        XCTAssertNil(reopened.noteForEditing(committed,bookID:bookID).graphRelationDraft,"Recovering a draft must not replace its choices with a stored relation.")
    }
    func testEditingExistingQuestionDoesNotOverwriteAnotherNoteAtTheSameRange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        let first = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2,/1:0,/1:2)",quote:"原文",chapter:"第一章",progress:0.1,note:"原来的想法")
        var question = first; question.id = UUID().uuidString; question.intent = .question; question.note = "为什么？"
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"",annotations:[first,question])]; reader.currentID = bookID
        question.questionResolved = true
        XCTAssertTrue(reader.saveGraphAnnotation(question,bookID:bookID,relation:nil))
        XCTAssertEqual(reader.currentAnnotations.count,2)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == first.id }?.note,first.note)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == first.id }?.intent,nil)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == question.id }?.questionResolved,true)
        question.color = .blue
        XCTAssertTrue(reader.saveAnnotation(question,bookID:bookID))
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == first.id }?.color,.yellow)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == question.id }?.color,.blue)
        XCTAssertTrue(reader.removeAnnotation(question.id,bookID:bookID))
        XCTAssertTrue(reader.restoreRemovedNote(try XCTUnwrap(reader.noteUndoID)))
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == first.id }?.note,first.note)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == question.id }?.questionResolved,true)
    }
    func testIncompleteRelationDraftRecoversWithoutCreatingNoteOrRelation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"甲",kind:.person)))
        let b = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"乙",kind:.person)))
        let draft = BookRelationDraft(sourceID:a,label:"是师父")
        XCTAssertTrue(reader.keepRelationDraft(draft))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.currentBook?.relationDrafts,[draft])
        XCTAssertTrue(reopened.currentAnnotations.isEmpty); XCTAssertTrue(reopened.bookNotesIndex.relations.isEmpty)
        XCTAssertNotNil(reopened.saveIndependentRelation(BookRelation(sourceID:a,targetID:b,label:draft.label,evidenceIDs:[]),draftID:draft.id))
        XCTAssertTrue(reopened.currentBook?.relationDrafts?.isEmpty == true)
        XCTAssertEqual(reopened.bookNotesIndex.relations.count,1)
    }

    func testRemovingEntityHidesItsConnectionsAndRestorationReusesItsIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"甲",kind:.person,aliases:["阿甲"])))
        let b = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"乙",kind:.person)))
        XCTAssertNotNil(reader.saveIndependentRelation(BookRelation(sourceID:a,targetID:b,label:"认识",evidenceIDs:[])))
        var note = ReaderAnnotation(cfi:"",quote:"甲与乙相识",chapter:"第一章",progress:0,note:"第一次见面")
        note.entityIDs = [a,b]
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        XCTAssertTrue(reader.setKnowledgeEntityDeleted(a,deleted:true))
        XCTAssertFalse(reader.bookNotesIndex.entities.contains { $0.id == a }); XCTAssertTrue(reader.bookNotesIndex.relations.isEmpty)
        note.note = "补充读后想法"
        XCTAssertTrue(reader.saveGraphAnnotation(note,bookID:bookID,relation:nil))
        XCTAssertTrue(reader.currentAnnotations[0].entityIDs?.contains(a) == true,"Editing a note must preserve its recoverable person link")
        XCTAssertEqual(reader.saveKnowledgeEntity(BookEntity(name:"阿甲",kind:.person)),a)
        XCTAssertEqual(reader.bookNotesIndex.relations.count,1)
        XCTAssertEqual(reader.bookNotesIndex.entities.count,2)
        XCTAssertTrue(reader.bookNotesIndex.notes.first?.entityIDs.contains(a) == true)
    }
    func testIndependentRelationCanBeCreatedWithoutNotesEditedRemovedAndRecovered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"",progress:0.3)]; reader.currentID = bookID
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"甲",kind:.person)))
        let b = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"乙",kind:.person)))
        let id = try XCTUnwrap(reader.saveIndependentRelation(BookRelation(sourceID:a,targetID:b,label:"认识",evidenceIDs:[])))
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        var value = try XCTUnwrap(reader.currentBook?.knowledgeRelations?.first)
        XCTAssertEqual(value.progress,0.3); XCTAssertEqual(value.standalone,true)
        value.label = "是师父"; XCTAssertEqual(reader.saveIndependentRelation(value),id)
        XCTAssertTrue(reader.setRelationDeleted(id,deleted:true)); XCTAssertTrue(reader.bookNotesIndex.relations.isEmpty)
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertTrue(reopened.bookNotesIndex.relations.isEmpty)
        XCTAssertTrue(reopened.setRelationDeleted(id,deleted:false))
        XCTAssertEqual(reopened.bookNotesIndex.relations.first?.label,"是师父")
        XCTAssertTrue(reopened.bookNotesIndex.visibleRelations(through:0.2).isEmpty)
        value.sourceID = b; value.targetID = b
        XCTAssertNil(reopened.saveIndependentRelation(value))
        XCTAssertEqual(reopened.bookNotesIndex.relations.first?.sourceID,a)
    }

    func testQuestionResponseRemainsLinkedAcrossReopenAndReopeningAQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID
        var question = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.1,note:"为何这样说？")
        question.intent = .question
        XCTAssertTrue(reader.saveGraphAnnotation(question,bookID:bookID,relation:nil))
        var response = try XCTUnwrap(reader.respondToQuestion(question.id)); response.note = "后面这一段解释了原因。"
        XCTAssertTrue(reader.saveGraphAnnotation(response,bookID:bookID,relation:nil))
        question.questionResolved = true
        XCTAssertTrue(reader.saveGraphAnnotation(question,bookID:bookID,relation:nil))
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID
        XCTAssertEqual(reopened.currentAnnotations.first { $0.id == response.id }?.responseToID,question.id)
        XCTAssertTrue(reopened.bookNotesIndex.openQuestions(through:1).isEmpty)
        question.questionResolved = false
        XCTAssertTrue(reopened.saveGraphAnnotation(question,bookID:bookID,relation:nil))
        XCTAssertEqual(reopened.bookNotesIndex.openQuestions(through:1).count,1)
        XCTAssertTrue(reopened.removeAnnotation(question.id,bookID:bookID))
        XCTAssertFalse(reopened.saveGraphAnnotation(response,bookID:bookID,relation:nil))
        XCTAssertEqual(reopened.currentAnnotations.first?.id,response.id)
    }

    func testSelectedTextOpensDirectlyInTheGraphAndStaleSelectionIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID
        var payload: [String:Any] = ["session":reader.annotationSessionID.uuidString,"id":UUID().uuidString,"cfi":"epubcfi(/6/2!/4/2,/1:0,/1:2)","quote":"原文","chapter":"第一章","chapterHref":"one.xhtml#small","progress":0.1,"color":"yellow"]
        reader.receiveAnnotation("annotationEdit",value:payload)
        XCTAssertTrue(reader.showNoteGraph)
        XCTAssertNil(reader.quickNoteDraft)
        XCTAssertEqual(reader.annotationDraft?.id,reader.graphNoteID)
        XCTAssertEqual(reader.annotationDraft?.annotation.quote,"原文")
        XCTAssertEqual(reader.annotationDraft?.annotation.chapterHref,"one.xhtml#small")
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        var item = try XCTUnwrap(reader.annotationDraft?.annotation); item.note = "在笔记系统中直接编辑"
        XCTAssertTrue(reader.saveGraphAnnotation(item,bookID:bookID,relation:nil))
        reader.annotationDraft = nil; reader.showNoteGraph = false
        reader.receiveAnnotation("annotationEdit",value:payload)
        XCTAssertEqual(reader.annotationDraft?.annotation.note,item.note)
        XCTAssertEqual(reader.currentAnnotations.count,1)
        reader.annotationDraft = nil; reader.showNoteGraph = false; payload["session"] = UUID().uuidString
        reader.receiveAnnotation("annotationEdit",value:payload)
        XCTAssertNil(reader.annotationDraft); XCTAssertFalse(reader.showNoteGraph)
        payload["session"] = reader.annotationSessionID.uuidString
        reader.receiveAnnotation("annotationQuestion",value:payload)
        XCTAssertNil(reader.annotationDraft); XCTAssertTrue(reader.currentAnnotations.count == 1)
        reader.beginQuickNote()
        XCTAssertTrue(reader.showNoteGraph); XCTAssertNotNil(reader.annotationDraft)
        XCTAssertNil(reader.quickNoteDraft)
    }
    func testRelationsAndNotesPersistTogetherAndDeletingEvidenceIsReversible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]
        reader.currentID = bookID
        reader.chapters = [ChapterItem(id:"one",href:"one.xhtml",title:"第一章",depth:0)]
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"林川",kind:.person,aliases:["青川客"])))
        let b = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"沈砚",kind:.person)))
        XCTAssertEqual(reader.saveKnowledgeEntity(BookEntity(name:"青川客",kind:.person)),a)
        var first = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.1,note:"这一段说明师徒关系")
        first.chapterHref = "one.xhtml"; first.entityIDs = [a,b]; first.title = "师徒身份确认"
        let relation = BookRelation(sourceID:a,targetID:b,label:"师父",evidenceIDs:[first.id])
        XCTAssertTrue(reader.saveGraphAnnotation(first,bookID:bookID,relation:relation))
        var second = first; second.id = UUID().uuidString; second.note = "另一条依据"
        XCTAssertTrue(reader.saveGraphAnnotation(second,bookID:bookID,relation:relation))
        XCTAssertEqual(reader.currentAnnotations.count,2,"Blank CFI chapter notes must remain distinct.")
        XCTAssertEqual(reader.bookNotesIndex.relations.count,1)
        XCTAssertEqual(Set(reader.bookNotesIndex.relations[0].evidenceIDs),Set([first.id,second.id]))
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        reopened.currentID = bookID; reopened.chapters = reader.chapters
        XCTAssertEqual(reopened.bookNotesIndex.search("青川客").count,2)
        XCTAssertTrue(reopened.removeAnnotation(first.id,bookID:bookID))
        XCTAssertEqual(reopened.bookNotesIndex.relations.count,1)
        XCTAssertTrue(reopened.restoreRemovedNote(try XCTUnwrap(reopened.noteUndoID)))
        XCTAssertEqual(Set(reopened.currentAnnotations.map(\.id)),Set([first.id,second.id]),"Restoring a chapter note must not replace another blank-CFI note.")
        XCTAssertTrue(reopened.removeAnnotation(first.id,bookID:bookID))
        XCTAssertTrue(reopened.removeAnnotation(second.id,bookID:bookID))
        XCTAssertEqual(reopened.bookNotesIndex.relations.count,1,"Explicitly saved relationships survive removal of their last source note.")
        XCTAssertTrue(reopened.restoreRemovedNote(try XCTUnwrap(reopened.noteUndoID)))
        XCTAssertEqual(reopened.bookNotesIndex.relations.count,1)
        XCTAssertEqual(reopened.currentAnnotations.first?.entityIDs?.count,2)
    }
    func testInvalidRelationCannotPartiallyCommitNoteChangesAndDraftKeepsItsPendingRelation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        reader.books = [LibraryBook(id:bookID,title:"测试",author:"",filename:"")]; reader.currentID = bookID
        let a = try XCTUnwrap(reader.saveKnowledgeEntity(BookEntity(name:"认知偏差",kind:.concept)))
        var note = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.1,note:"未完成的知识笔记")
        note.entityIDs = [a]
        note.graphRelationDraft = BookRelation(sourceID:a,targetID:a,label:"属于",evidenceIDs:[note.id])
        try reader.keepTextDraft(note,bookID:bookID)
        XCTAssertFalse(reader.saveGraphAnnotation(note,bookID:bookID,relation:note.graphRelationDraft))
        XCTAssertTrue(reader.currentAnnotations.isEmpty)
        XCTAssertTrue(reader.currentBook?.knowledgeRelations?.isEmpty != false)
        let draft = try XCTUnwrap(reader.noteDraftStore.textDrafts(bookID:bookID).first)
        XCTAssertEqual(draft.annotation.graphRelationDraft?.label,"属于")
        XCTAssertEqual(draft.annotation.note,note.note)
    }
}
