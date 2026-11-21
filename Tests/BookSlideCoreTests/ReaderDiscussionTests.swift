import XCTest
@testable import BookSlideCore

final class ReaderDiscussionTests: XCTestCase {
    func testNoteOnlyDiscussionDoesNotPretendToHaveAnOriginalExcerpt() {
        var annotation = note(); annotation.quote = "  \n"
        var discussion = ReaderDiscussion(); discussion.messages = [.init(role:.user,text:"帮我梳理笔记")]
        annotation.discussion = discussion
        let request = ReaderDiscussionPrompt.build(title:"书",author:"",annotation:annotation,nearby:"",related:[])
        XCTAssertEqual(request.context.sources.map(\.id),["我的笔记"])
        XCTAssertEqual(request.context.sources.first?.text,annotation.note)
        XCTAssertEqual(request.messages.last?.content,"帮我梳理笔记")
    }
    private func note() -> ReaderAnnotation {
        ReaderAnnotation(cfi:"epubcfi(/6/2!/4/2,/1:0,/1:8)",quote:"更多信息未必带来更好的判断。",chapter:"第一章",progress:0.3,note:"要为判断留出空间。")
    }
    func testLegacyNotesAndStructuredDiscussionRoundTripThroughDrafts() throws {
        let old = try JSONEncoder().encode(note())
        XCTAssertNil(try JSONDecoder().decode(ReaderAnnotation.self,from:old).discussion)
        var annotation = note(), discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"为什么？"),.init(role:.assistant,text:"要留出思考空间。",state:.interrupted,model:"测试")]
        discussion.composer = "我的后续问题"
        annotation.discussion = discussion
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let book = UUID(), store = ReaderNoteDraftStore(libraryDirectory:root)
        try store.save(ReaderTextNoteDraft(bookID:book,annotation:annotation))
        XCTAssertEqual(try store.textDrafts(bookID:book).first?.annotation,annotation)
        let index = BookNotesIndex(entries:[],annotations:[annotation],pageNotes:[],entities:[],relations:[])
        XCTAssertFalse(try XCTUnwrap(index.notes.first).highlightOnly)
        XCTAssertEqual(index.search("思考空间").count,1)
        XCTAssertTrue(index.notes[0].text.contains("未完成"))
        XCTAssertTrue(index.notes[0].text.contains(annotation.note))
    }
    func testContextRespectsOptOutReadBoundaryAndDoesNotPromoteAIAnswersToSources() {
        var annotation = note(), discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"解释"),.init(role:.assistant,text:"AI 自己的推测"),.init(role:.user,text:"继续")]
        annotation.discussion = discussion
        var before = note(); before.id = UUID().uuidString; before.progress = 0.1
        before.discussion = discussion
        var future = before; future.progress = 0.9; future.note = "未来情节"
        let request = ReaderDiscussionPrompt.build(title:"书",author:"作者",annotation:annotation,nearby:"此前正文",related:[before,future])
        XCTAssertEqual(request.context.sources.map(\.id),["原文","附近正文","我的笔记","笔记1"])
        XCTAssertFalse(request.context.sources.contains { $0.text.contains("AI 自己的推测") || $0.text.contains("未来情节") })
        XCTAssertEqual(request.messages.last?.content,"继续")
        XCTAssertEqual(request.messages.dropFirst(2).map(\.role),["user","assistant","user"])
        annotation.discussion?.includeNearby = false; annotation.discussion?.includeRelatedNotes = false
        let excluded = ReaderDiscussionPrompt.build(title:"书",author:"",annotation:annotation,nearby:"不应发送",related:[before])
        XCTAssertEqual(excluded.context.sources.map(\.id),["原文","我的笔记"])
    }
    func testLongConversationKeepsRecentWholeTurnsAndFirstQuestionAndBoundsSources() {
        var annotation = note(), discussion = ReaderDiscussion()
        annotation.quote = String(repeating:"文",count:12000)
        for i in 0..<20 {
            discussion.messages += [.init(role:.user,text:"问题\(i)"),.init(role:.assistant,text:String(repeating:"回答\(i)",count:500))]
        }
        discussion.messages += [.init(role:.user,text:"请继续解释"),.init(role:.assistant,text:"不能作为完整回答",state:.interrupted)]
        annotation.discussion = discussion
        let request = ReaderDiscussionPrompt.build(title:"书",author:"",annotation:annotation,nearby:String(repeating:"前",count:5000),related:[])
        XCTAssertTrue(request.context.sources[0].truncated)
        XCTAssertEqual(request.context.sources[0].text.count,8000)
        XCTAssertEqual(request.context.sources[1].text.count,3000)
        XCTAssertGreaterThan(request.context.omittedTurns,0)
        XCTAssertEqual(request.context.sources.last?.text,"问题0")
        let messages = Array(request.messages.dropFirst(2))
        XCTAssertEqual(messages.last?.content,"请继续解释")
        XCTAssertLessThanOrEqual(messages.count,13)
        XCTAssertLessThanOrEqual(messages.reduce(0) { $0 + $1.content.count },18000)
        XCTAssertFalse(messages.contains { $0.content == "不能作为完整回答" })
    }
    func testRequestUsesOfficialModelAndKeepsCredentialsOutOfBody() throws {
        let client = ReaderDiscussionClient(apiKey:"test-secret")
        let request = try client.urlRequest(messages:[.init(role:"user",content:"原文问题")])
        XCTAssertEqual(request.url?.absoluteString,"https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-secret")
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(body["model"] as? String,"deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool,true)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("test-secret"))
        XCTAssertThrowsError(try ReaderDiscussionClient(apiKey:"").urlRequest(messages:[]))
        let luna = ReaderDiscussionClient(apiKey:"bridge-token",endpoint:URL(string:"https://bridge.test/chat/completions")!,usesLuna:true)
        let lunaRequest = try luna.urlRequest(messages:[.init(role:"user",content:"原文问题")])
        let lunaBody = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(lunaRequest.httpBody)) as? [String:Any])
        XCTAssertEqual(lunaBody["model"] as? String,"gpt-6-luna")
        XCTAssertNil(lunaBody["thinking"])
    }
    @MainActor func testRoutingOnlyFallsBackBeforeAnyAnswerWhenLunaIsUnreachable() async throws {
        var providers: [ReaderAIProvider] = []
        var answer = ""
        let fallback: ReaderAIService.Stream = { _,output in try output("备用回答") }

        let connected = ReaderAIService(luna:{ _,output in try output("首选回答") },deepSeek:fallback)
        try await connected.stream(messages:[],onProvider:{ providers.append($0) }) { answer += $0 }
        XCTAssertEqual(providers,[.luna])
        XCTAssertEqual(answer,"首选回答")

        providers = []; answer = ""
        let unavailable = ReaderAIService(luna:{ _,_ in throw URLError(.cannotConnectToHost) },deepSeek:fallback)
        try await unavailable.stream(messages:[],onProvider:{ providers.append($0) }) { answer += $0 }
        XCTAssertEqual(providers,[.luna,.deepSeek])
        XCTAssertEqual(answer,"备用回答")

        for expected in [ReaderDiscussionError.http(429),.http(401),.incomplete] {
            providers = []; answer = ""
            let reachable = ReaderAIService(luna:{ _,output in
                if expected == .incomplete { try output("已收到") }
                throw expected
            },deepSeek:fallback)
            do {
                try await reachable.stream(messages:[],onProvider:{ providers.append($0) }) { answer += $0 }
                XCTFail("Expected Luna error")
            } catch { XCTAssertEqual(error as? ReaderDiscussionError,expected) }
            XCTAssertEqual(providers,[.luna])
            XCTAssertEqual(answer,expected == .incomplete ? "已收到" : "")
        }

        providers = []
        let lostStream = ReaderAIService(luna:{ _,output in
            try output("部分回答")
            throw URLError(.networkConnectionLost)
        },deepSeek:fallback)
        do {
            try await lostStream.stream(messages:[],onProvider:{ providers.append($0) }) { _ in }
            XCTFail("A network failure after output must be visible")
        } catch { XCTAssertEqual((error as? URLError)?.code,.networkConnectionLost) }
        XCTAssertEqual(providers,[.luna])
    }
    func testWholeBookDiscussionAndTranslationUseTheirOwnMaterial() throws {
        var annotation = note(); annotation.quote = ""; annotation.note = ""
        var discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"What is a metaphor?")]
        annotation.discussion = discussion
        let source = ReaderDiscussionSource(id:"已读正文1",label:"摘录",text:"第一章里记录了观察。",limit:100)
        let request = ReaderDiscussionPrompt.build(title:"书",author:"",annotation:annotation,nearby:"",related:[],readingSources:[source])
        XCTAssertEqual(request.context.sources,[source])
        XCTAssertEqual(request.messages.last?.content,"What is a metaphor?")
        XCTAssertTrue(request.messages.first?.content.contains("直接回答读者实际提出的问题") == true)
        XCTAssertFalse(request.messages.first?.content.contains("梳理") == true)
        discussion.messages = [.init(role:.user,text:"全书主线是什么？")]
        let legacyThread = try JSONSerialization.jsonObject(with:JSONEncoder().encode(["book":discussion]))
        let legacy = try JSONSerialization.data(withJSONObject:["version":1,"nodes":[],"edges":[],"readingDiscussions":legacyThread])
        let graph = try JSONDecoder().decode(ReadingGraph.self,from:legacy)
        let note = try XCTUnwrap(graph.annotations.first)
        XCTAssertEqual(note.discussionScope,ReaderDiscussion.bookScope)
        XCTAssertEqual(note.discussion,discussion)
        XCTAssertEqual(note.title,"AI 对话")
        XCTAssertNotNil(graph.node(.init(.discussion,note.id)))
        let encoded = try JSONEncoder().encode(graph)
        XCTAssertNil((try JSONSerialization.jsonObject(with:encoded) as? [String:Any])?["readingDiscussions"])
        XCTAssertEqual(try JSONDecoder().decode(ReadingGraph.self,from:encoded).annotations,[note])
        XCTAssertEqual(note.discussionLabel("AI 读懂全书"),"AI 对话")
        XCTAssertEqual(note.discussionLabel("我的读书问题"),"我的读书问题")

        let passage = String(repeating:"冬天的图书馆很安静。\n",count:200)
        let parts = ReaderDiscussionPrompt.translationPassages(passage)
        XCTAssertEqual(parts.joined(),passage)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1400 })
        let translation = ReaderDiscussionPrompt.translation(parts[0],into:"English")
        XCTAssertEqual(translation.messages.map(\.role),["system","user"])
        XCTAssertEqual(translation.messages.last?.content,parts[0])
        XCTAssertTrue(translation.messages.first?.content.contains("English") == true)
    }
    @MainActor func testStreamReadsChineseAndDetectsTruncationHTTPFailuresAndBrokenStreams() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DiscussionURLProtocol.self]
        let session = URLSession(configuration:configuration); defer { session.invalidateAndCancel() }
        let client = ReaderDiscussionClient(apiKey:"test",endpoint:URL(string:"https://discussion.test/chat/completions")!)
        let first = "data: {\"choices\":[{\"delta\":{\"content\":\"中文🌱\"},\"finish_reason\":null}]}\n\n"
        DiscussionURLProtocol.status = 200; DiscussionURLProtocol.body = ": keepalive\n\n" + first + "data: [DONE]\n\n"
        var text = ""
        try await client.stream(messages:[],session:session) { text += $0 }
        XCTAssertEqual(text,"中文🌱")
        DiscussionURLProtocol.body = first
        do { try await client.stream(messages:[],session:session) { _ in }; XCTFail("Broken stream must fail") }
        catch { XCTAssertEqual(error as? ReaderDiscussionError,.incomplete) }
        DiscussionURLProtocol.body = first + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n"
        do { try await client.stream(messages:[],session:session) { _ in }; XCTFail("Token limit must be visible") }
        catch { XCTAssertEqual(error as? ReaderDiscussionError,.tooLong) }
        DiscussionURLProtocol.status = 401
        do { try await client.stream(messages:[],session:session) { _ in }; XCTFail("Unauthorized") }
        catch { XCTAssertEqual(error as? ReaderDiscussionError,.http(401)) }
    }
    @MainActor func testLocalCodexMultiTurnIntegration() async throws {
        guard ProcessInfo.processInfo.environment["BOOKSLIDE_CODEX_TEST"] == "1" else { throw XCTSkip("Run with the local Codex bridge for live inference") }
        var annotation = note(), discussion = ReaderDiscussion()
        discussion.messages = [.init(role:.user,text:"请只用一句话，解释选文中信息与判断的关系，并标明依据。")]
        annotation.discussion = discussion
        let client = ReaderDiscussionClient(apiKey:"local-codex",endpoint:URL(string:"http://127.0.0.1:8787/chat/completions")!,usesLuna:true)
        let first = ReaderDiscussionPrompt.build(title:"判断与信息",author:"测试",annotation:annotation,nearby:"信息需要经过思考才能用于决策。",related:[])
        var answer = ""
        try await client.stream(messages:first.messages) { answer += $0 }
        XCTAssertFalse(answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(answer.contains("[原文]") || answer.contains("[附近正文]"))
        discussion.messages += [.init(role:.assistant,text:answer),.init(role:.user,text:"基于刚才的解释，给一个日常生活中的小例子，用一句话。")]
        annotation.discussion = discussion
        let followup = ReaderDiscussionPrompt.build(title:"判断与信息",author:"测试",annotation:annotation,nearby:"信息需要经过思考才能用于决策。",related:[])
        var second = ""
        try await client.stream(messages:followup.messages) { second += $0 }
        XCTAssertFalse(second.isEmpty)
        print("CODEX_DISCUSSION_FIRST: \(answer)\nCODEX_DISCUSSION_FOLLOWUP: \(second)")
    }
}

private final class DiscussionURLProtocol: URLProtocol {
    static var status = 200
    static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "discussion.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        // Split even inside UTF-8 scalars to exercise URLSession's decoder.
        for byte in Self.body.utf8 { client?.urlProtocol(self,didLoad:Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
