import XCTest
@testable import BookSlideCore

final class ReadingGraphTests: XCTestCase {
    func testCompletedDiscussionIsSearchableAndLinkableByQuestionWithoutDuplicatingMessages() throws {
        var note = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"林川指着石碑。",chapter:"山门前",progress:0.4)
        var discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"这个动作说明什么？"),.init(role:.assistant,text:"表现出郑重。[原文]")]
        note.discussion = discussion
        let person = BookEntity(name:"林川",kind:.person)
        var graph = ReadingGraph(annotations:[note],entities:[person])
        let thread = ReadingNodeID(.discussion,note.id)
        guard case .discussion(let stored) = try XCTUnwrap(graph.node(thread)).content else { return XCTFail("Missing discussion") }
        XCTAssertTrue(stored.messages.isEmpty,"Messages remain separate graph nodes")
        XCTAssertEqual(graph.title(for:thread),"这个动作说明什么？")
        XCTAssertTrue(graph.search("这个动作").contains { $0.id == thread })
        let edge = ReadingEdge(kind:.association,source:.init(.entity,person.id.uuidString),target:thread,label:"关联")
        try graph.apply(.connect(edge))
        XCTAssertTrue(graph.searchEdges("这个动作").contains(edge))
        let restored = try JSONDecoder().decode(ReadingGraph.self,from:JSONEncoder().encode(graph))
        XCTAssertEqual(restored.title(for:thread),"这个动作说明什么？")
        XCTAssertTrue(restored.search("这个动作").contains { $0.id == thread })
        XCTAssertTrue(restored.searchEdges("这个动作").contains(edge))
    }
    func testSelectionRecordsPersonWithSourceAndReusesAliasWithoutOverwritingNoteOrConversation() throws {
        let person = BookEntity(name:"林川",kind:.person,aliases:["青川客"])
        var note = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"青川客带沈砚走进山门。",chapter:"山门前",progress:0.4,note:"我的想法")
        var discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"他的动作说明什么？"),.init(role:.assistant,text:"这里表现出克制。[原文]")]
        note.discussion = discussion
        var graph = ReadingGraph(annotations:[note],entities:[person])
        var stale = note; stale.id = UUID().uuidString; stale.note = ""; stale.discussion = nil
        let id = try graph.recordEntity(BookEntity(name:"青川客",kind:.person),from:stale)
        XCTAssertEqual(id,person.id)
        XCTAssertEqual(graph.entities.count,1)
        XCTAssertEqual(graph.annotations.count,1)
        XCTAssertEqual(graph.annotations.first?.note,note.note)
        XCTAssertEqual(graph.annotations.first?.discussion,discussion)
        XCTAssertEqual(graph.annotations.first?.entityIDs,[person.id])
        XCTAssertEqual(graph.node(.init(.source,note.id,local:"excerpt"))?.text,note.quote)
        XCTAssertTrue(graph.edges.contains { $0.id.kind == .mentions && $0.id.target == .init(.entity,person.id.uuidString) })
        // A conversation uses exactly the same connection API as a note.
        let edge = ReadingEdge(kind:.association,source:.init(.discussion,note.id),target:.init(.entity,id.uuidString),label:"解读人物")
        try graph.apply(.connect(edge))
        _ = try graph.recordEntity(BookEntity(name:"青川客",kind:.person),from:stale)
        XCTAssertTrue(graph.edges.contains(edge))
        XCTAssertEqual(graph.annotations.count,1)
        let restored = try JSONDecoder().decode(ReadingGraph.self,from:JSONEncoder().encode(graph))
        XCTAssertEqual(restored,graph)
    }
    func testSelectionCanRecordACustomNameAndRetainItsSource() throws {
        var graph = ReadingGraph()
        let selection = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"沈砚向林川行了弟子礼。",chapter:"山门前",progress:0.4)
        let id = try graph.recordEntity(BookEntity(name:" 师徒关系 ",kind:.concept),from:selection)
        XCTAssertEqual(graph.entities.first?.id,id)
        XCTAssertEqual(graph.entities.first?.name,"师徒关系")
        XCTAssertEqual(graph.annotations.first?.cfi,selection.cfi)
        XCTAssertEqual(graph.annotations.first?.quote,selection.quote)
        XCTAssertEqual(graph.annotations.first?.entityIDs,[id])
        XCTAssertEqual(try graph.recordEntity(BookEntity(name:"师徒关系",kind:.concept),from:selection),id)
        XCTAssertEqual(graph.entities.count,1)
    }
    func testInvalidSelectedNodeNamesAndSourcesLeaveNoPartialChanges() throws {
        var graph = ReadingGraph()
        let selection = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"沈砚向林川行了弟子礼。",chapter:"山门前",progress:0.4)
        for name in ["", " \n ", String(repeating:"名",count:81)] {
            XCTAssertThrowsError(try graph.recordEntity(BookEntity(name:name,kind:.concept),from:selection))
            XCTAssertTrue(graph.nodes.isEmpty)
        }
        var missingSource = selection; missingSource.quote = " \n "
        XCTAssertThrowsError(try graph.recordEntity(BookEntity(name:"师徒关系",kind:.concept),from:missingSource))
        XCTAssertTrue(graph.nodes.isEmpty)
    }
    private func sample() -> (ReaderAnnotation,BookEntity,BookEntity,BookRelation) {
        let a = BookEntity(name:"林川",kind:.person,aliases:["青川客"]), b = BookEntity(name:"沈砚",kind:.person)
        var note = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"须先学会静心。",chapter:"山门前",progress:0.4,note:"耐心帮助理解。")
        note.title = "静心"; note.entityIDs = [a.id,b.id]; note.responseToID = "earlier-question"
        var discussion = ReaderDiscussion(); discussion.composer = "继续追问"; discussion.includeNearby = false
        let question = ReaderDiscussionMessage(role:.user,text:"静心与阅读有什么关系？")
        var answer = ReaderDiscussionMessage(role:.assistant,text:"先保留自己的疑问。",model:"测试模型")
        answer.context = .init(sources:[.init(id:"原文",label:"山门前",text:note.quote,locator:note.cfi,limit:100)],omittedTurns:2)
        discussion.messages = [question,answer]; note.discussion = discussion
        var relation = BookRelation(sourceID:a.id,targetID:b.id,label:"师父",evidenceIDs:[note.id]); relation.standalone = true
        return (note,a,b,relation)
    }
    func testOneGraphRoundTripsAllTypesAndDirectedLinksWithoutNestedCopies() throws {
        let (note,a,b,relation) = sample()
        let graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let data = try JSONEncoder().encode(graph), restored = try JSONDecoder().decode(ReadingGraph.self,from:data)
        XCTAssertEqual(restored.annotations,[note]); XCTAssertEqual(restored.entities,[a,b]); XCTAssertEqual(restored.relations,[relation])
        XCTAssertEqual(Set(restored.nodes.map { $0.id.kind }),[.note,.entity,.discussion,.message,.source])
        let noteID = ReadingNodeID(.note,note.id)
        XCTAssertEqual(restored.edges.filter { $0.id.kind == .mentions }.map { $0.id.source },[noteID,noteID])
        let edge = try XCTUnwrap(restored.edges.first { $0.id.kind == .relationship })
        XCTAssertEqual(edge.id.source,.init(.entity,a.id.uuidString)); XCTAssertEqual(edge.id.target,.init(.entity,b.id.uuidString))
        guard case .note(let stored) = try XCTUnwrap(restored.node(noteID)).content else { return XCTFail("Missing note") }
        XCTAssertNil(stored.value.discussion); XCTAssertNil(stored.value.entityIDs); XCTAssertEqual(stored.value.quote,"")
        XCTAssertTrue(restored.nodes.contains { if case .message(let stored) = $0.content { return stored.value.context == nil }; return false })
    }
    func testSearchFindsPeopleAliasesConversationAndHistoricalEvidence() {
        let (note,a,b,relation) = sample(); let graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        XCTAssertEqual(graph.search("青川客").map { $0.id.kind },[.entity])
        XCTAssertEqual(graph.search("保留自己的疑问").map { $0.id.kind },[.message])
        XCTAssertTrue(graph.search("须先学会静心").contains { $0.id.kind == .source })
        XCTAssertEqual(graph.search("继续追问").map { $0.id.kind },[.discussion])
    }
    func testNodeDeletionAndRestoreShareOwnershipRulesAndKeepPeople() throws {
        let (note,a,b,relation) = sample(); var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let original = graph, id = ReadingNodeID(.note,note.id)
        try graph.apply(.remove(id))
        XCTAssertTrue(graph.annotations.isEmpty); XCTAssertEqual(graph.entities,[a,b])
        XCTAssertTrue(graph.nodes.filter { $0.id.owner == note.id }.allSatisfy { $0.deletedAt != nil })
        try graph.apply(.restore(id)); XCTAssertEqual(graph,original)
        try graph.apply(.remove(.init(.discussion,note.id)))
        XCTAssertNil(graph.annotations.first?.discussion)
        XCTAssertTrue(graph.search("保留自己的疑问").isEmpty)
        try graph.apply(.restore(.init(.discussion,note.id))); XCTAssertEqual(graph.annotations.first?.discussion,note.discussion)
    }
    func testCrossTypeConnectionsAreAtomicAndDeletedEndpointsCannotBeLinked() throws {
        let (note,a,b,relation) = sample(); var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let thread = ReadingNodeID(.discussion,note.id), person = ReadingNodeID(.entity,a.id.uuidString)
        let connection = ReadingEdge(kind:.association,source:thread,target:person,label:"讨论人物",record:UUID())
        try graph.apply(.connect(connection)); XCTAssertTrue(graph.edges.contains(connection))
        let original = graph
        XCTAssertThrowsError(try graph.apply(.connect(.init(kind:.association,source:thread,target:.init(.note,"missing"),label:"引用"))))
        XCTAssertEqual(graph,original)
        try graph.apply(.remove(person))
        XCTAssertThrowsError(try graph.apply(.connect(connection)))
        try graph.apply(.restore(person)); try graph.apply(.disconnect(connection.id))
        XCTAssertNotNil(graph.edges.first { $0.id == connection.id }?.deletedAt)
        try graph.apply(.restoreConnection(connection.id)); XCTAssertTrue(graph.edges.contains(connection))
    }
    func testLegacyAdaptersKeepCustomConnectionsWhenContentChanges() throws {
        var (note,a,b,relation) = sample(); var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let connection = ReadingEdge(kind:.association,source:.init(.discussion,note.id),target:.init(.entity,a.id.uuidString),label:"讨论人物",record:UUID())
        try graph.apply(.connect(connection))
        let messages = note.discussion?.messages; note.note += "继续整理。"
        graph.replaceAnnotations([note]); graph.replaceRelations([relation])
        XCTAssertEqual(graph.annotations.first?.discussion?.messages,messages)
        XCTAssertTrue(graph.edges.contains(connection)); XCTAssertEqual(graph.entities,[a,b])
        XCTAssertEqual(graph.annotations.first?.responseToID,"earlier-question")
    }
    func testSameIdentifierAcrossTypesAndThreadsDoesNotCollide() throws {
        let (original,a,b,relation) = sample(); var first = original, second = original
        first.id = a.id.uuidString; second.id = "second-note"
        let graph = ReadingGraph(annotations:[first,second],entities:[a,b],relations:[relation])
        XCTAssertEqual(graph.annotations.count,2)
        XCTAssertEqual(graph.nodes.filter { $0.id.kind == .message }.count,4)
        XCTAssertEqual(Set(graph.nodes.map(\.id)).count,graph.nodes.count)
        XCTAssertNoThrow(try JSONDecoder().decode(ReadingGraph.self,from:JSONEncoder().encode(graph)))
    }
    func testUnknownVersionAndDuplicateIdentitiesAreRejected() throws {
        let (note,a,b,relation) = sample(); let graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(graph)) as? [String:Any])
        json["version"] = 999
        XCTAssertThrowsError(try JSONDecoder().decode(ReadingGraph.self,from:JSONSerialization.data(withJSONObject:json)))
        json["version"] = 1
        var nodes = try XCTUnwrap(json["nodes"] as? [[String:Any]]); nodes.append(nodes[0]); json["nodes"] = nodes
        XCTAssertThrowsError(try JSONDecoder().decode(ReadingGraph.self,from:JSONSerialization.data(withJSONObject:json)))
    }
    func testParentEditsKeepRemovedConversationRecoverableAndRemovalIsIdempotent() throws {
        let (note,a,b,relation) = sample()
        var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let thread = ReadingNodeID(.discussion,note.id)
        try graph.apply(.remove(thread),at:Date(timeIntervalSince1970:10))
        try graph.apply(.remove(thread),at:Date(timeIntervalSince1970:20))
        var edited = try XCTUnwrap(graph.annotations.first); edited.note = "删除讨论后继续写笔记"
        graph.replaceAnnotations([edited])
        let reopened = try JSONDecoder().decode(ReadingGraph.self,from:JSONEncoder().encode(graph))
        graph = reopened; try graph.apply(.restore(thread))
        XCTAssertEqual(graph.annotations.first?.note,edited.note)
        XCTAssertEqual(graph.annotations.first?.discussion,note.discussion)
    }
    func testSourceRemovalIsVisibleToAdaptersAndCanBeRestored() throws {
        let (note,a,b,relation) = sample()
        var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let excerpt = ReadingNodeID(.source,note.id,local:"excerpt")
        try graph.apply(.remove(excerpt)); XCTAssertEqual(graph.annotations.first?.quote,"")
        graph.replaceAnnotations(graph.annotations)
        try graph.apply(.restore(excerpt)); XCTAssertEqual(graph.annotations.first?.quote,note.quote)
    }
    func testIndividuallyRemovedMessageSurvivesParentEditsWithOriginalOrder() throws {
        var (note,a,b,relation) = sample()
        let last = ReaderDiscussionMessage(role:.user,text:"新的追问")
        note.discussion?.messages.append(last)
        var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let middle = try XCTUnwrap(note.discussion?.messages[1])
        let messageID = ReadingNodeID(.message,note.id,local:middle.id.uuidString)
        try graph.apply(.remove(messageID))
        var edited = try XCTUnwrap(graph.annotations.first); edited.note += "继续整理"
        graph.replaceAnnotations([edited]); try graph.apply(.restore(messageID))
        XCTAssertEqual(graph.annotations.first?.discussion?.messages,note.discussion?.messages)
        XCTAssertEqual(graph.edges.first { $0.id.source.local == last.id.uuidString && $0.id.kind == .responds }?.id.target,messageID)
    }
    func testNodeDraftsAreScopedAndIdentifiersCannotEscapeTheirDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ReadingNodeDraftStore(libraryDirectory:root), book = UUID(), otherBook = UUID()
        let person = BookEntity(name:"尚未完成的人物",kind:.person)
        let id = ReadingNodeID(.entity,"../../outside/秘密")
        let draft = ReadingNodeDraft(bookID:book,node:.init(id:id,content:.entity(person)))
        try store.save(draft)
        XCTAssertEqual(try store.load(bookID:book,id:id),draft)
        XCTAssertNil(try store.load(bookID:otherBook,id:id))
        XCTAssertEqual(try store.drafts(bookID:book),[draft])
        let files = try FileManager.default.contentsOfDirectory(at:store.directory.appendingPathComponent(book.uuidString),includingPropertiesForKeys:nil)
        XCTAssertEqual(files.count,1); XCTAssertEqual(files.first?.lastPathComponent.count,69)
        try store.remove(bookID:book,id:id); XCTAssertTrue(try store.drafts(bookID:book).isEmpty)
    }
    func testInvalidUpsertCannotPartiallyMutateCanonicalGraph() throws {
        let (note,a,b,relation) = sample()
        var graph = ReadingGraph(annotations:[note],entities:[a,b],relations:[relation])
        let before = graph
        let invalid = ReadingNode(id:.init(.entity,"wrong-id"),content:.entity(a))
        XCTAssertThrowsError(try graph.apply(.upsert(invalid))); XCTAssertEqual(graph,before)
    }
}
