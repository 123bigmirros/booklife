import XCTest
import BookSlideCore
@testable import BookSlideMac

@MainActor final class MindMapDocumentTests: XCTestCase {
    private func fixture() throws -> (URL,ReaderModel,UUID,ReaderAnnotation,UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = ReaderModel(directory:root,loadExternalSources:false), bookID = UUID()
        var note = ReaderAnnotation(cfi:"",quote:"原文依据",chapter:"第一章",progress:0.2,note:"结构图直接显示这段正文。")
        note.title = "原主题"; note.chapterHref = "chapter.xhtml"
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"为什么？"),.init(role:.assistant,text:"先查原文证据。")]; note.discussion = discussion
        reader.books = [.init(id:bookID,title:"结构图",author:"",filename:"",locator:"saved-reading-position",annotations:[note])]; reader.currentID = bookID
        reader.chapters = [.init(id:"chapter",href:"chapter.xhtml",title:"第一章",depth:0)]
        let person = try XCTUnwrap(reader.saveKnowledgeEntity(.init(name:"林川",kind:.person,aliases:["青川客"])))
        return (root,reader,bookID,note,person)
    }
    @discardableResult private func mutate(_ topic: inout MindMapTopic,id: String,_ action: (inout MindMapTopic) -> Void) -> Bool {
        if topic.id == id { action(&topic); return true }
        for i in topic.children.indices { if mutate(&topic.children[i],id:id,action) { return true } }
        return false
    }
    private func remove(_ topic: inout MindMapTopic,id: String) -> MindMapTopic? {
        if let i = topic.children.firstIndex(where:{ $0.id == id }) { return topic.children.remove(at:i) }
        for i in topic.children.indices { if let node = remove(&topic.children[i],id:id) { return node } }
        return nil
    }
    func testEngineEditsReparentingFoldAndUndoPreserveContentAndReadingPosition() throws {
        let (root,reader,bookID,note,person) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        var before = reader.mindMapDocument(), changed = before
        let childToken = "engine-created-topic"
        XCTAssertTrue(mutate(&changed.nodeData,id:note.id) { $0.children.append(.init(id:childToken,topic:"一个分支")) })
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID),reader.error ?? "")
        let child = try XCTUnwrap(reader.currentAnnotations.first { $0.id != note.id })
        XCTAssertEqual(reader.mindMapToken(.init(.note,child.id)),childToken)
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains { $0.id.source == .init(.note,note.id) && $0.id.target == .init(.note,child.id) } == true)
        before = reader.mindMapDocument(); changed = before
        XCTAssertEqual(try before.flattened().first { $0.topic.id == note.id }?.topic.topic,note.note)
        let updatedText = String(repeating:"编辑后的同一段内容。",count:48)
        mutate(&changed.nodeData,id:note.id) { $0.topic = updatedText; $0.note = "旧正文" }
        let moved = try XCTUnwrap(remove(&changed.nodeData,id:childToken)), target = reader.mindMapToken(.init(.entity,person.uuidString))
        XCTAssertTrue(mutate(&changed.nodeData,id:target) { $0.children.append(moved); $0.expanded = false })
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID),reader.error ?? "")
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,updatedText)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.title,note.title)
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.discussion,note.discussion)
        XCTAssertEqual(reader.currentBook?.locator,"saved-reading-position")
        XCTAssertTrue(reader.currentBook?.graph.searchEdges("").contains { $0.id.source == .init(.entity,person.uuidString) && $0.id.target == .init(.note,child.id) && $0.label == "子主题" } == true)
        var rearranged = reader.mindMapDocument()
        mutate(&rearranged.nodeData,id:note.id) { $0.topic = "拖动时画布仍带着过时的正文"; $0.expanded = false }
        rearranged.editedTopics = []
        XCTAssertTrue(reader.applyMindMapDocument(rearranged,baseline:reader.mindMapDocument(),bookID:bookID))
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,updatedText)
        let saved = reader.mindMapDocument()
        let reopened = ReaderModel(directory:root,loadExternalSources:false); reopened.currentID = bookID; reopened.chapters = reader.chapters
        XCTAssertEqual(try reopened.mindMapDocument().flattened().first { $0.topic.id == childToken }?.parent,target)
        XCTAssertEqual(try reopened.mindMapDocument().flattened().first { $0.topic.id == target }?.topic.expanded,false)
        changed = saved; XCTAssertNotNil(remove(&changed.nodeData,id:childToken))
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:saved,bookID:bookID))
        XCTAssertTrue(reader.removedNotes.contains { $0.annotation?.id == child.id })
        XCTAssertTrue(reader.applyMindMapDocument(saved,baseline:reader.mindMapDocument(),bookID:bookID),reader.error ?? "")
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == child.id }?.note,"一个分支")
        XCTAssertFalse(reader.removedNotes.contains { $0.annotation?.id == child.id })
    }
    func testConnectionRenameRemovalAndRestorationUseTheSameGraphEdge() throws {
        let (root,reader,bookID,note,person) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        var before = reader.mindMapDocument(), changed = before
        let target = reader.mindMapToken(.init(.entity,person.uuidString))
        changed.arrows.append(.init(id:"new-engine-arrow",label:"涉及",from:note.id,to:target))
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID),reader.error ?? "")
        before = reader.mindMapDocument(); changed = before
        let i = try XCTUnwrap(changed.arrows.firstIndex { $0.label == "涉及" })
        let edgeID = try XCTUnwrap(changed.arrows[i].edgeID)
        changed.arrows[i].label = "解释"
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID))
        XCTAssertEqual(reader.currentBook?.graph.edges.first { $0.id == edgeID }?.label,"解释")
        before = reader.mindMapDocument(); changed = before; changed.arrows.removeAll { $0.edgeID == edgeID }
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID))
        XCTAssertFalse(reader.currentBook?.graph.searchEdges("").contains { $0.id == edgeID } == true)
    }
    func testRejectedSourceEditsAndFailedWritesKeepTheGraphAndRecoverableDraft() throws {
        let (root,reader,bookID,note,_) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let original = reader.currentBook?.graph, before = reader.mindMapDocument()
        var changed = before; changed.nodeData.topic = "不能改掉书名"
        XCTAssertFalse(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID))
        XCTAssertEqual(reader.currentBook?.graph,original)
        changed = before; mutate(&changed.nodeData,id:note.id) { $0.topic = "写入失败也要保留" }
        let index = root.appendingPathComponent("library.json"), held = root.appendingPathComponent("held-library.json")
        try FileManager.default.moveItem(at:index,to:held); try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
        XCTAssertFalse(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID))
        XCTAssertEqual(reader.currentBook?.graph,original)
        XCTAssertEqual(reader.loadMindMapRecovery(bookID)?.document,changed)
        try FileManager.default.removeItem(at:index); try FileManager.default.moveItem(at:held,to:index)
        XCTAssertTrue(reader.applyMindMapDocument(changed,baseline:before,bookID:bookID))
        XCTAssertNil(reader.loadMindMapRecovery(bookID))
    }
    func testEngineLeafDefaultsDecodeAndLegacyGraphHasNoRequiredCanvasState() throws {
        let leaf = try JSONDecoder().decode(MindMapTopic.self,from:Data(#"{"id":"leaf","topic":"主题"}"#.utf8))
        XCTAssertEqual(leaf.children,[]); XCTAssertTrue(leaf.expanded)
        let graph = ReadingGraph(annotations:[.init(cfi:"",quote:"",chapter:"",progress:0,note:"笔记")])
        let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(graph)) as? [String:Any]
        XCTAssertNil(object?["canvasNodes"])
        XCTAssertEqual(try JSONDecoder().decode(ReadingGraph.self,from:JSONEncoder().encode(graph)),graph)
    }

    func testChapterArrangementPersistsWithoutChangingBookContents() throws {
        let (root,reader,bookID,note,_) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        reader.chapters.append(.init(id:"second",href:"second.xhtml",title:"第二章",depth:0))
        let chapters = reader.chapters
        let before = reader.mindMapDocument()
        let first = try XCTUnwrap(before.nodeData.children.first { $0.metadata?.chapterID == 0 })
        let second = try XCTUnwrap(before.nodeData.children.first { $0.metadata?.chapterID == 1 })
        var arranged = before
        _ = remove(&arranged.nodeData,id:first.id)
        XCTAssertTrue(mutate(&arranged.nodeData,id:second.id) { $0.children.append(first) })
        XCTAssertTrue(reader.applyMindMapDocument(arranged,baseline:before,bookID:bookID),reader.error ?? "")
        let reopened = ReaderModel(directory:root,loadExternalSources:false)
        reopened.currentID = bookID; reopened.chapters = chapters
        XCTAssertEqual(try reopened.mindMapDocument().flattened().first { $0.topic.id == first.id }?.parent,second.id)
        XCTAssertEqual(reader.chapters.map(\.href),chapters.map(\.href))
        XCTAssertEqual(reader.currentAnnotations.first { $0.id == note.id }?.note,note.note)
        let saved = reader.mindMapDocument()
        var invalid = before
        let chapter = try XCTUnwrap(remove(&invalid.nodeData,id:second.id))
        // A book's chapter cannot become a child of an editable note.
        XCTAssertTrue(mutate(&invalid.nodeData,id:note.id) { $0.children.append(chapter) })
        XCTAssertFalse(reader.applyMindMapDocument(invalid,baseline:saved,bookID:bookID))
    }
}
