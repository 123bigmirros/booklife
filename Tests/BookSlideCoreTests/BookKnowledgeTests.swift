import XCTest
@testable import BookSlideCore

final class BookKnowledgeTests: XCTestCase {
    func testSelectedPeopleKeepSourcesWithoutDuplicateThoughtCardsAfterReopening() throws {
        var graph = ReadingGraph()
        var sources: [ReaderAnnotation] = []
        for (offset,name) in ["霍华德·洛克","吉丁太太"].enumerated() {
            let source = ReaderAnnotation(cfi:"epubcfi(/6/\(offset*2+2)!/4/2)",quote:name,chapter:"第一章",progress:0.2)
            sources.append(source)
            let id = try graph.recordEntity(BookEntity(name:name,kind:.person),from:source)
            var reselection = source; reselection.id = UUID().uuidString
            XCTAssertEqual(try graph.recordEntity(BookEntity(name:name,kind:.person),from:reselection),id)
        }
        let reopened = try JSONDecoder().decode(ReadingGraph.self,from:JSONEncoder().encode(graph))
        let index = BookNotesIndex(entries:[],graph:reopened)
        XCTAssertEqual(index.entities.count,2)
        XCTAssertTrue(index.notes.filter(\.showsOnCanvas).isEmpty,"Adding people must not also display same-name thought cards")
        XCTAssertEqual(index.notes.filter(\.entitySourceOnly).count,2)
        XCTAssertEqual(reopened.annotations.count,2,"Keep source anchors available to the entity inspector and export")
        for source in sources {
            XCTAssertEqual(reopened.node(.init(.source,source.id,local:"excerpt"))?.text,source.quote)
            XCTAssertEqual(index.notes.first { $0.id == source.id }?.locator,source.cfi)
        }
        XCTAssertEqual(reopened.edges.filter { $0.id.kind == .mentions }.count,2)
    }

    func testEntitySourcesBecomeCanvasNotesWhenTheReaderAddsContentOrConnections() throws {
        var graph = ReadingGraph()
        let source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"吉丁太太",chapter:"第一章",progress:0.2)
        let id = try graph.recordEntity(BookEntity(name:source.quote,kind:.person),from:source)
        let saved = try XCTUnwrap(graph.annotations.first)
        var variants: [ReaderAnnotation] = []
        var thought = saved; thought.note = "这是我对她的第一印象"; variants.append(thought)
        var titled = saved; titled.title = "初次出场"; variants.append(titled)
        var question = saved; question.intent = .question; variants.append(question)
        var explicitThought = saved; explicitThought.intent = .thought; variants.append(explicitThought)
        var discussion = saved
        discussion.discussion = ReaderDiscussion(); discussion.discussion?.composer = "她和洛克是什么关系？"
        variants.append(discussion)
        var response = saved; response.responseToID = "previous-question"; variants.append(response)
        for note in variants {
            let index = BookNotesIndex(entries:[],annotations:[note],pageNotes:[],entities:graph.entities,relations:[])
            XCTAssertEqual(index.notes.filter(\.showsOnCanvas).map(\.id),[source.id])
            XCTAssertFalse(try XCTUnwrap(index.notes.first).entitySourceOnly)
        }
        let edge = ReadingEdge(kind:.association,source:.init(.note,source.id),target:.init(.entity,id.uuidString),label:"初次印象")
        try graph.apply(.connect(edge))
        XCTAssertEqual(BookNotesIndex(entries:[],graph:graph).notes.filter(\.showsOnCanvas).map(\.id),[source.id])
        try graph.apply(.disconnect(edge.id))
        XCTAssertTrue(BookNotesIndex(entries:[],graph:graph).notes.filter(\.showsOnCanvas).isEmpty)
        try graph.apply(.restoreConnection(edge.id))
        XCTAssertEqual(BookNotesIndex(entries:[],graph:graph).notes.filter(\.showsOnCanvas).map(\.id),[source.id])
    }

    func testLegacyEntityEvidenceAndUnlinkedHighlightsKeepTheirRoles() throws {
        let a = BookEntity(name:"甲",kind:.person), b = BookEntity(name:"乙",kind:.person)
        var source = ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2)",quote:"甲与乙是师徒",chapter:"第一章",progress:0.2)
        source.entityIDs = [a.id,b.id]
        let highlight = ReaderAnnotation(cfi:"epubcfi(/6/4!/4/2)",quote:"一处普通划线",chapter:"第一章",progress:0.2)
        let relation = BookRelation(sourceID:a.id,targetID:b.id,label:"师父",evidenceIDs:[source.id])
        let index = BookNotesIndex(entries:[],annotations:[source,highlight],pageNotes:[],entities:[a,b],relations:[relation])
        XCTAssertTrue(try XCTUnwrap(index.notes.first { $0.id == source.id }).showsOnCanvas,"Explicit relationship evidence remains visible")
        XCTAssertTrue(try XCTUnwrap(index.notes.first { $0.id == highlight.id }).highlightOnly)
        XCTAssertEqual(index.relations,[relation])
        let legacy = BookNotesIndex(entries:[],annotations:[source],pageNotes:[],entities:[a,b],relations:[])
        XCTAssertTrue(try XCTUnwrap(legacy.notes.first).entitySourceOnly,"Old source records also stop producing duplicate thought cards")
    }

    func testThingTypesPreserveLegacyValuesAndRoundTrip() throws {
        for kind in BookEntityKind.allCases {
            let entity = BookEntity(name:kind.title,kind:kind,aliases:["另一个名称"])
            XCTAssertEqual(try JSONDecoder().decode(BookEntity.self,from:JSONEncoder().encode(entity)),entity)
        }
        for raw in ["person","concept"] {
            let json = "{\"id\":\"\(UUID())\",\"name\":\"旧卡片\",\"kind\":\"\(raw)\",\"aliases\":[]}"
            let entity = try JSONDecoder().decode(BookEntity.self,from:Data(json.utf8))
            XCTAssertEqual(entity.kind.rawValue,raw)
            XCTAssertNil(entity.progress)
        }
    }
    func testThingAndRelationSearchUsesAliasesTypesAndProgressWithoutNeedingNotes() {
        var person = BookEntity(name:"林川",kind:.person,aliases:["青川客"]); person.progress = 0.1
        var organization = BookEntity(name:"云山书院",kind:.organization,aliases:["书院"]); organization.progress = 0.2
        var place = BookEntity(name:"临江",kind:.place); place.progress = 0.2
        var future = BookEntity(name:"归来",kind:.event); future.progress = 0.9
        var joins = BookRelation(sourceID:person.id,targetID:organization.id,label:"加入",evidenceIDs:[]); joins.standalone = true; joins.progress = 0.2
        var located = BookRelation(sourceID:organization.id,targetID:place.id,label:"位于",evidenceIDs:[]); located.standalone = true; located.progress = 0.3
        var late = BookRelation(sourceID:person.id,targetID:future.id,label:"参与",evidenceIDs:[]); late.standalone = true; late.progress = 0.9
        let index = BookNotesIndex(entries:[],annotations:[],pageNotes:[],entities:[person,organization,place,future],relations:[joins,located,late])
        XCTAssertEqual(index.matchingEntities(" 青川客 ",through:0.5).map(\.id),[person.id])
        XCTAssertEqual(index.matchingEntities(kind:.place,through:0.5).map(\.id),[place.id])
        XCTAssertTrue(index.matchingEntities(kind:.event,through:0.5).isEmpty)
        XCTAssertEqual(index.matchingEntities(kind:.event,through:0.5,includeFuture:true).map(\.id),[future.id])
        XCTAssertEqual(index.matchingRelations("青川客",through:0.5).map(\.id),[joins.id])
        XCTAssertEqual(index.matchingRelations("位于",through:0.5).map(\.id),[located.id])
        XCTAssertEqual(index.matchingRelations(kind:.organization,through:0.5).count,2)
        XCTAssertTrue(index.matchingRelations("参与",through:0.5).isEmpty)
        XCTAssertEqual(index.matchingRelations("参与",through:0.5,includeFuture:true).map(\.id),[late.id])
        XCTAssertTrue(index.matchingRelations("书院",kind:.event,through:1).isEmpty)
    }
    func testWritingSuggestsExistingAliasesAndFindsRelatedInkWithoutLinkingAutomatically() {
        let person = BookEntity(name:"林川",kind:.person,aliases:["青川客"])
        var removed = BookEntity(name:"青川",kind:.person); removed.deletedAt = Date()
        var future = BookEntity(name:"结局",kind:.concept); future.progress = 0.9
        var old = ReaderAnnotation(cfi:"old",quote:"原句",chapter:"第二章",progress:0.2,note:"以前的理解")
        old.entityIDs = [person.id]
        let chapter = ReaderAnnotation(cfi:"chapter",quote:"同章摘录",chapter:"第一章",progress:0.3)
        var late = old; late.id = "future"; late.progress = 0.9
        var anchor = ReaderPageAnchor(locator:"ink",chapter:"第二章",progress:0.4,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"x")
        anchor.chapterHref = "two"
        var ink = ReaderPageNote(assetID:UUID(),anchor:anchor); ink.entityIDs = [person.id]
        var writing = ReaderAnnotation(cfi:"new",quote:"青川客谈起结局",chapter:"第一章",progress:0.5,note:"新的想法")
        writing.chapterHref = "./one"
        let index = BookNotesIndex(entries:[.init(title:"第一章",href:"one",depth:0),.init(title:"第二章",href:"two",depth:0)],annotations:[old,chapter,late,writing],pageNotes:[ink],entities:[person,removed,future],relations:[])
        XCTAssertEqual(index.suggestedEntities(for:writing,through:0.5).map(\.id),[person.id])
        let related = index.relatedNotes(for:writing,through:0.5).map(\.id)
        XCTAssertEqual(Set(related),Set([old.id,chapter.id,ink.id.uuidString]))
        XCTAssertEqual(related.last,chapter.id,"Explicit subjects rank ahead of other notes in the chapter.")
        XCTAssertNil(writing.entityIDs,"Suggestions require an explicit choice.")
        writing.entityIDs = [person.id]
        XCTAssertTrue(index.suggestedEntities(for:writing,through:0.5).isEmpty)
        XCTAssertEqual(index.relatedNotes(for:writing,through:0.5).map(\.id),related)
    }
    func testRelatedChapterNotesDoNotMixRepeatedHeadings() {
        let a = ReaderAnnotation(cfi:"a",quote:"前篇",chapter:"第一章",progress:0.1)
        var b = a; b.id = "b"; b.chapterHref = "b#chapter"
        let entries: [BookStructure.Entry] = [.init(title:"第一章",href:"a#chapter",depth:0),.init(title:"第一章",href:"b#chapter",depth:0)]
        let index = BookNotesIndex(entries:entries,annotations:[a,b],pageNotes:[],entities:[],relations:[])
        var writing = a; writing.id = "new"
        XCTAssertTrue(index.relatedNotes(for:writing,through:1).isEmpty)
        writing.chapterHref = "./b#chapter"
        XCTAssertEqual(index.relatedNotes(for:writing,through:1).map(\.id),[b.id])
    }
    func testStandaloneRelationshipsAndQuestionsRespectReadingProgress() throws {
        let a = BookEntity(name:"林川",kind:.person), b = BookEntity(name:"沈砚",kind:.person)
        var early = BookRelation(sourceID:a.id,targetID:b.id,label:"认识",evidenceIDs:[])
        early.standalone = true; early.progress = 0.2
        var late = early; late.id = UUID(); late.label = "师父"; late.progress = 0.8
        var question = ReaderAnnotation(cfi:"q",quote:"疑惑原文",chapter:"第一章",progress:0.1)
        question.intent = .question
        var answered = question; answered.id = UUID().uuidString; answered.questionResolved = true
        var future = question; future.id = UUID().uuidString; future.progress = 0.9
        var response = ReaderAnnotation(cfi:"r",quote:"",chapter:"第二章",progress:0.3,note:"我现在的理解")
        response.responseToID = question.id
        let plain = ReaderAnnotation(cfi:"h",quote:"只想划线",chapter:"第一章",progress:0.1)
        let index = BookNotesIndex(entries:[],annotations:[question,answered,future,response,plain],pageNotes:[],entities:[a,b],relations:[early,late])
        XCTAssertEqual(index.visibleRelations(through:0.4).map(\.id),[early.id])
        XCTAssertEqual(index.visibleRelations(through:0.1,includeFuture:true).count,2)
        XCTAssertEqual(index.openQuestions(through:0.4).map(\.id),[question.id])
        XCTAssertEqual(index.notes.first { $0.id == response.id }?.responseToID,question.id)
        XCTAssertTrue(try XCTUnwrap(index.notes.first { $0.id == plain.id }).highlightOnly)
        XCTAssertFalse(try XCTUnwrap(index.notes.first { $0.id == question.id }).highlightOnly)
        var removed = early; removed.deletedAt = Date()
        XCTAssertTrue(BookNotesIndex(entries:[],annotations:[],pageNotes:[],entities:[a,b],relations:[removed]).relations.isEmpty)
    }

    func testLegacyRecordsDecodeWithoutReadingMetadataAndNewQuestionRoundTrips() throws {
        let a = UUID(), b = UUID()
        let old = "{\"id\":\"\(UUID())\",\"sourceID\":\"\(a)\",\"targetID\":\"\(b)\",\"label\":\"师父\",\"evidenceIDs\":[],\"conjecture\":false}"
        let relation = try JSONDecoder().decode(BookRelation.self,from:Data(old.utf8))
        XCTAssertNil(relation.standalone); XCTAssertNil(relation.deletedAt)
        var question = ReaderAnnotation(cfi:"",quote:"",chapter:"第一章",progress:0.1,note:"为什么？")
        question.intent = .question; question.questionResolved = false
        XCTAssertEqual(try JSONDecoder().decode(ReaderAnnotation.self,from:JSONEncoder().encode(question)),question)
    }
    func testRepeatedChapterTitlesUseSourceDestinationsAndLegacyAmbiguityIsVisible() {
        let entries: [BookStructure.Entry] = [.init(title:"第一章",href:"a.xhtml#one",depth:0),.init(title:"第一章",href:"a.xhtml#two",depth:0)]
        var precise = ReaderAnnotation(cfi:"cfi",quote:"原文",chapter:"第一章",progress:0.4)
        precise.chapterHref = "./a.xhtml#two"
        let legacy = ReaderAnnotation(cfi:"other",quote:"旧笔记",chapter:"第一章",progress:0.1)
        let index = BookNotesIndex(entries:entries,annotations:[precise,legacy],pageNotes:[],entities:[],relations:[])
        XCTAssertEqual(index.notes.first { $0.id == precise.id }?.chapterID,1)
        XCTAssertNil(index.notes.first { $0.id == legacy.id }?.chapterID)
        XCTAssertEqual(index.notes(in:nil).map(\.id),[legacy.id])
    }
    func testAliasesFindSourceNotesAndFutureRelationshipsStayHidden() {
        let a = BookEntity(name:"林川",kind:.person,aliases:["青川客"]), b = BookEntity(name:"沈砚",kind:.person)
        var note = ReaderAnnotation(cfi:"cfi",quote:"原文",chapter:"第二章",progress:0.7,note:"师徒")
        note.entityIDs = [a.id,b.id]
        let edge = BookRelation(sourceID:a.id,targetID:b.id,label:"师父",evidenceIDs:[note.id])
        let index = BookNotesIndex(entries:[.init(title:"第二章",href:"a",depth:0)],annotations:[note],pageNotes:[],entities:[a,b],relations:[edge])
        XCTAssertEqual(index.search("青川客").map(\.id),[note.id])
        XCTAssertTrue(index.visibleRelations(through:0.4).isEmpty)
        XCTAssertEqual(index.visibleRelations(through:0.8),[edge])
        let removed = BookNotesIndex(entries:[],annotations:[],pageNotes:[],entities:[a,b],relations:[edge])
        XCTAssertTrue(removed.relations.isEmpty)
        XCTAssertEqual(index.visibleRelations(through:0.1,includeFuture:true),[edge])
    }
    func testParentChapterIncludesChildNotesAndInkUsesTheSameSourceIndex() {
        let entries: [BookStructure.Entry] = [.init(title:"上篇",href:"",depth:0),.init(title:"第一节",href:"one",depth:1),.init(title:"下篇",href:"two",depth:0)]
        var anchor = ReaderPageAnchor(locator:"cfi",chapter:"第一节",progress:0.2,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"x")
        anchor.chapterHref = "one"
        let ink = ReaderPageNote(assetID:UUID(),anchor:anchor)
        let index = BookNotesIndex(entries:entries,annotations:[],pageNotes:[ink],entities:[],relations:[])
        XCTAssertEqual(index.notes(in:0).map(\.id),[ink.id.uuidString])
        XCTAssertTrue(index.notes(in:2).isEmpty)
        XCTAssertTrue(index.notes[0].ink)
    }
}
