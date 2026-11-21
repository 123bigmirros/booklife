import XCTest
@testable import BookSlideCore

final class InkGroupingTests: XCTestCase {
    private func anchor(_ spans: [ReaderInkTextSpan]) -> ReaderPageAnchor {
        var a=ReaderPageAnchor(locator:"source",chapter:"第一章",progress:0,referenceX:0,referenceY:0,viewportWidth:600,viewportHeight:800,layoutKey:"layout")
        a.textSpans=spans;return a
    }
    private func span(_ id: String,block: String = "p",offset: Int = 0,x: Double = 20,y: Double) -> ReaderInkTextSpan {
        .init(id:id,block:block,offset:offset,text:"阅读原文",boxes:[.init(x:x,y:y,width:80,height:20)])
    }
    func testCircleAndUnderlineOnSamePassageMakeOneNode() {
        let a=anchor([span("one",y:40)])
        let groups=ReaderInkGrouping.plan([.init(id:"circle",bounds:.init(x:18,y:38,width:86,height:26)),.init(id:"underline",bounds:.init(x:20,y:63,width:80,height:3))],canvasID:UUID(),anchor:a,previous:[])
        XCTAssertEqual(groups.count,1);XCTAssertEqual(Set(groups.flatMap { $0.flatMap(\.strokes) }),["circle","underline"])
        XCTAssertEqual(groups[0][0].sources.first?.text,"阅读原文")
    }
    func testContinuousLinesJoinButSeparatePassagesStayIndependent() {
        let a=anchor([span("one",offset:0,y:40),span("two",offset:4,y:72),span("three",block:"other",y:400)])
        let groups=ReaderInkGrouping.plan([.init(id:"a",bounds:.init(x:20,y:61,width:80,height:3)),.init(id:"b",bounds:.init(x:20,y:93,width:80,height:3)),.init(id:"c",bounds:.init(x:20,y:421,width:80,height:3))],canvasID:UUID(),anchor:a,previous:[])
        XCTAssertEqual(groups.count,2);XCTAssertEqual(groups[0].count,2)
    }
    func testManualSplitAndLaterWritingPreserveBothNodeIdentities() {
        let canvas=UUID(),a=anchor([span("same",y:40)])
        func note(_ stroke: String,x: Double) -> ReaderPageNote {
            var n=ReaderPageNote(assetID:UUID(),anchor:a)
            n.parts=[.init(id:n.id,canvasID:canvas,assetID:n.assetID,anchor:a,bounds:.init(x:x,y:42,width:12,height:12),strokeIDs:[stroke],sources:a.textSpans!)];n.manualGrouping=true;return n
        }
        let one=note("a",x:22),two=note("b",x:66)
        let groups=ReaderInkGrouping.plan([.init(id:"a",bounds:.init(x:22,y:42,width:12,height:12)),.init(id:"b",bounds:.init(x:66,y:42,width:12,height:12)),.init(id:"new",bounds:.init(x:24,y:44,width:5,height:7))],canvasID:canvas,anchor:a,previous:[one,two])
        XCTAssertEqual(groups.count,2);XCTAssertEqual(Set(groups.flatMap { $0.compactMap(\.owner) }),[one.id,two.id])
        XCTAssertTrue(groups.first(where:{ $0.contains { $0.owner==one.id } })!.flatMap(\.strokes).contains("new"))
    }
    func testAmbiguousMarginCommentDoesNotChooseAnArbitraryPassage() {
        let a=anchor([.init(id:"a",block:"one",offset:0,text:"甲",boxes:[.init(x:0,y:20,width:50,height:20)]),.init(id:"b",block:"two",offset:0,text:"乙",boxes:[.init(x:130,y:20,width:50,height:20)])])
        let groups=ReaderInkGrouping.plan([.init(id:"a",bounds:.init(x:0,y:20,width:50,height:20)),.init(id:"b",bounds:.init(x:130,y:20,width:50,height:20)),.init(id:"comment",bounds:.init(x:66,y:20,width:30,height:20))],canvasID:UUID(),anchor:a,previous:[])
        XCTAssertEqual(groups.count,3)
    }
    func testLegacyPageNotesDecodeWithoutGroupingFields() throws {
        let old=ReaderPageNote(assetID:UUID(),anchor:anchor([]))
        let decoded=try JSONDecoder().decode(ReaderPageNote.self,from:JSONEncoder().encode(old))
        XCTAssertNil(decoded.parts);XCTAssertEqual(decoded.inkParts.count,1);XCTAssertEqual(decoded.inkParts[0].id,old.id)
    }
    func testSplittablePartsDoNotReviveAssociationsRemovedFromTheGroup() {
        let canvas=UUID(),kept=UUID(),removed=UUID(),a=anchor([])
        var note=ReaderPageNote(assetID:UUID(),anchor:a)
        var part=ReaderInkPart(id:UUID(),canvasID:canvas,assetID:note.assetID,anchor:a,bounds:.init(x:20,y:20,width:80,height:30),strokeIDs:["one"],sources:[])
        part.entityIDs=[kept,removed]
        var second=part;second.id=UUID();second.strokeIDs=["two"]
        note.parts=[part,second];note.entityIDs=[kept]
        XCTAssertEqual(note.inkParts.map(\.entityIDs),[[kept],[kept]])
        note.entityIDs=[]
        XCTAssertTrue(note.inkParts.allSatisfy { $0.entityIDs?.isEmpty == true })
    }
}

extension InkGroupingTests {
    func testChangingLayoutAddsInkToTheExistingPassageNode() {
        let oldCanvas=UUID(),newCanvas=UUID(),a=anchor([span("same-source",y:40)])
        var note=ReaderPageNote(assetID:UUID(),anchor:a)
        note.parts=[.init(id:note.id,canvasID:oldCanvas,assetID:note.assetID,anchor:a,bounds:.init(x:20,y:40,width:80,height:20),strokeIDs:["old"],sources:a.textSpans!)]
        var reflowed=a;reflowed.layoutKey="larger-font";reflowed.textSpans=[span("same-source",x:80,y:200)]
        let groups=ReaderInkGrouping.plan([.init(id:"new",bounds:.init(x:80,y:220,width:80,height:3))],canvasID:newCanvas,anchor:reflowed,previous:[note])
        XCTAssertEqual(groups.count,1);XCTAssertEqual(groups[0][0].owner,note.id)
        XCTAssertEqual(groups[0][0].id,newCanvas,"The new layout retains a separate editable part within the same node")
    }
}
