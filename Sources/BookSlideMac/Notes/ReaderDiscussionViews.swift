import SwiftUI
import Security
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Native apps keep user credentials in Keychain, outside the library and exports.
enum ReaderDiscussionCredentials {
    private static func keychainQuery(_ luna: Bool) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:luna ? "dev.bookslide.luna" : "dev.bookslide.deepseek",kSecAttrAccount as String:"api-key"]
    }
    static func load(luna: Bool = false) throws -> String {
        let query = keychainQuery(luna)
        var value = query; value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary,&result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data:data,encoding:.utf8) else { throw failure(status) }
        return key
    }
    static func save(_ key: String, luna: Bool = false) throws {
        let query = keychainQuery(luna)
        let key = key.trimmingCharacters(in:.whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }; return
        }
        let attributes = [kSecValueData as String:Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            var value = query; value.merge(attributes) { _,new in new }
            value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(value as CFDictionary,nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain:"BookSlideKeychain",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"系统钥匙串暂时不可用（\(status)）。请重试。"])
    }
    static var developmentEndpoint: URL? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["BOOKSLIDE_DISCUSSION_ENDPOINT"], let url = URL(string:raw),
           url.scheme == "http", ["127.0.0.1","localhost","[::1]"].contains(url.host ?? "") { return url }
        #endif
        return nil
    }
    static let bridgeSetting = "readerLunaBridge"
    static func bridgeURL(_ raw: String) -> URL? {
        guard let parts = URLComponents(string:raw), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1","localhost","[::1]"].contains(host))
        else { return nil }
        return parts.url
    }
    static func service() -> ReaderAIService {
        let fallback = try? load()
        let deepSeek: ReaderAIService.Stream? = fallback.flatMap { key in
            guard !key.isEmpty else { return nil }
            let client = ReaderDiscussionClient(apiKey:key)
            return { messages, output in try await client.stream(messages:messages,onText:output) }
        }
        return ReaderAIService(luna:{ messages, output in
            if let endpoint = developmentEndpoint {
                let client = ReaderDiscussionClient(apiKey:"local-codex",endpoint:endpoint,usesLuna:true)
                try await client.stream(messages:messages,onText:output)
            } else if let endpoint = bridgeURL(UserDefaults.standard.string(forKey:bridgeSetting) ?? "") {
                let key = try load(luna:true)
                let loopback = ["127.0.0.1","localhost","[::1]"].contains(endpoint.host ?? "")
                guard loopback || !key.isEmpty else { throw ReaderDiscussionError.lunaUnavailable }
                let client = ReaderDiscussionClient(apiKey:key.isEmpty ? "local-codex" : key,endpoint:endpoint,usesLuna:true)
                try await client.stream(messages:messages,onText:output)
            } else {
                #if os(macOS)
                try await ReaderLocalLuna.stream(messages:messages,onText:output)
                #elseif targetEnvironment(simulator)
                let client = ReaderDiscussionClient(apiKey:"local-codex",endpoint:URL(string:"http://127.0.0.1:8787/chat/completions")!,usesLuna:true)
                try await client.stream(messages:messages,onText:output)
                #else
                throw ReaderDiscussionError.lunaUnavailable
                #endif
            }
        },deepSeek:deepSeek)
    }
    static func configureFromLaunchEnvironment() throws {
        #if DEBUG && os(iOS)
        // A development install can provision the explicitly supplied key over
        // Apple's device connection. The key never enters the app bundle,
        // library, launch arguments, or logs, and is removed from the environment.
        guard let raw = getenv("BOOKSLIDE_DEEPSEEK_BOOTSTRAP_KEY") else { return }
        let key = String(cString:raw)
        unsetenv("BOOKSLIDE_DEEPSEEK_BOOTSTRAP_KEY")
        try save(key)
        print("BOOKSLIDE_AI_KEYCHAIN_READY")
        #endif
    }
}

#if os(macOS)
private enum ReaderLocalLuna {
    static func stream(messages: [ReaderChatMessage],onText: @escaping ReaderAIService.Output) async throws {
        guard let executable = codexExecutable() else { throw ReaderDiscussionError.lunaUnavailable }
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("bookslide-luna-\(UUID())",isDirectory:true)
        try manager.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? manager.removeItem(at:folder) }
        let input = folder.appendingPathComponent("request")
        let output = folder.appendingPathComponent("answer")
        let events = folder.appendingPathComponent("events")
        let data = try JSONEncoder().encode(messages)
        try Data(("You are a book-reading and translation assistant. Use no tools. Follow the system message and answer the final user message in this JSON conversation:\n" + String(decoding:data,as:UTF8.self)).utf8).write(to:input)
        let stdin = try FileHandle(forReadingFrom:input)
        try Data().write(to:events)
        let stdout = try FileHandle(forWritingTo:events)
        defer { try? stdin.close(); try? stdout.close() }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.arguments = ["exec","--model",ReaderAIProvider.luna.model,"--ephemeral","--ignore-user-config",
            "--skip-git-repo-check","--sandbox","read-only","-c","features.shell_tool=false",
            "-c","features.multi_agent=false","-c","web_search=\"disabled\"","-c","apps._default.enabled=false",
            "-c","project_doc_max_bytes=0","--json","--output-last-message",output.path,"-"]
        process.standardInput = stdin
        process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw ReaderDiscussionError.lunaUnavailable }
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(50)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw ReaderDiscussionError.lunaUnavailable }
            try await Task.sleep(for:.milliseconds(100))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw failure(in:events) }
        guard let answer = try? String(contentsOf:output,encoding:.utf8),
              !answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ReaderDiscussionError.invalidResponse }
        guard answer.count <= 32000 else { throw ReaderDiscussionError.tooLong }
        try await onText(answer)
    }

    private static func failure(in events: URL) -> ReaderDiscussionError {
        let transcript = (try? String(contentsOf:events,encoding:.utf8)) ?? ""
        let message = transcript.split(separator:"\n").reversed().compactMap { line -> String? in
            guard let event = (try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any] else { return nil }
            if event["type"] as? String == "turn.failed", let error = event["error"] as? [String:Any] { return error["message"] as? String }
            if event["type"] as? String == "error" { return event["message"] as? String }
            return nil
        }.first?.lowercased()
        guard let message else { return .lunaUnavailable }
        if let match = message.range(of:#"(?<=status )[45]\d\d"#,options:.regularExpression),
           let status = Int(message[match]) { return .http(status) }
        if message.contains("usage limit") || message.contains("rate limit") { return .http(429) }
        if ["disconnected","connection","timed out","error sending request","not logged in","login required"]
            .contains(where:{ message.contains($0) }) { return .lunaUnavailable }
        return .invalidResponse
    }

    private static func codexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let installed = (try? FileManager.default.contentsOfDirectory(atPath:nvm.path)) ?? []
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init)
            + [home.appendingPathComponent(".local/bin").path,"/opt/homebrew/bin","/usr/local/bin"]
            + installed.sorted { $0.compare($1,options:.numeric) == .orderedDescending }.map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        return paths.lazy.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath:$0,isDirectory:true).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath:$0.path) }
    }
}
#endif

@MainActor final class ReaderDiscussionRun: ObservableObject {
    @Published private(set) var running = false
    @Published var failure: String?
    private var task: Task<Void,Never>?
    private var update: ((String,ReaderDiscussionMessage.State,String?) -> Void)?
    private var text = ""
    private var provider: String?
    private var generation = UUID()
    func start(service: ReaderAIService, requests: [ReaderDiscussionRequest],
               update: @escaping (String,ReaderDiscussionMessage.State,String?) -> Void) {
        guard !running else { return }
        running = true; failure = nil; text = ""; provider = nil; self.update = update
        let token = UUID(); generation = token
        task = Task { [weak self] in
            guard let self else { return }
            var last = Date.distantPast
            var answeredBy: [String] = []
            var activeProvider: ReaderAIProvider?
            do {
                for request in requests {
                    var started = false
                    try await service.stream(messages:request.messages,onProvider:{ selected in
                        guard self.generation == token else { return }
                        activeProvider = selected
                        self.provider = (answeredBy + (answeredBy.contains(selected.rawValue) ? [] : [selected.rawValue])).joined(separator:" / ")
                        self.update?(self.text,.streaming,self.provider)
                    }) { [weak self] delta in
                        guard let self, self.generation == token else { throw CancellationError() }
                        if !started && !self.text.isEmpty { self.text += "\n\n" }
                        started = true; self.text += delta
                        if Date().timeIntervalSince(last) >= 0.08 { self.update?(self.text,.streaming,self.provider); last = Date() }
                    }
                    if let name = activeProvider?.rawValue, !answeredBy.contains(name) { answeredBy.append(name) }
                }
                guard generation == token else { return }
                self.update?(text,.complete,provider)
            } catch {
                guard generation == token else { return }
                self.update?(text,Task.isCancelled ? .interrupted : .failed,provider)
                if !Task.isCancelled {
                    if let aiError = error as? ReaderDiscussionError, [.http(401),.http(403)].contains(aiError), activeProvider == .luna {
                        failure = "Codex Luna 认证失败，请检查 Codex 登录或 AI 设置中的桥接令牌。"
                    } else { failure = (error as? ReaderDiscussionError)?.localizedDescription ?? "连接中断或超时，已保留收到的内容。请检查网络后重试。" }
                }
            }
            self.update = nil; running = false; task = nil
        }
    }
    func stop() {
        guard running else { return }
        generation = UUID(); task?.cancel(); task = nil
        update?(text,.interrupted,provider); update = nil; running = false
    }
}

/// A discussion opened from selected text has its own presentation and lifetime.
/// It reuses the conversation engine without requiring the notes workspace.
struct ReaderSelectionDiscussion: View {
    @ObservedObject var reader: ReaderModel
    let draft: ReaderAnnotationDraft
    let close: () -> Void
    var embedded = false
    var connect: ((ReadingNodeID) -> Void)?
    @State private var item: ReaderAnnotation
    @State private var baseline: ReaderAnnotation
    @State private var status = "自动保存"
    @State private var failure: String?
    @State private var linking = false
    @State private var discussionRunning = false
    @State private var createdConnection: ReadingEdge.ID?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    private var palette: BookGraphPalette { .init(dark:colorScheme == .dark,readingTheme:embedded ? reader.appearance.theme : nil) }
    init(reader: ReaderModel,draft: ReaderAnnotationDraft,embedded: Bool = false,connect: ((ReadingNodeID) -> Void)? = nil,close: @escaping () -> Void) {
        self.reader = reader; self.draft = draft; self.close = close
        self.embedded = embedded; self.connect = connect
        let value = reader.noteForEditing(draft.annotation,bookID:draft.bookID)
        _item = State(initialValue:value); _baseline = State(initialValue:value)
    }
    var body: some View {
        if draft.translates {
            ReaderTranslationPanel(passage:draft.annotation.quote,palette:palette,close:close)
        } else { discussionBody }
    }
    private var discussionBody: some View {
        VStack(spacing:0) {
            ReadingEditorHeader(title:"AI 对话",symbol:"bubble.left.and.bubble.right",status:status,statusID:"selection-discussion-save-status",titleID:"selection-discussion-title",back:embedded ? { if persist() { close() } } : nil,backLabel:"关闭 AI 对话") {
                ReadingToolButton(symbol:"link",label:"添加连接") {
                    if persist() {
                        if let connect { connect(.init(.discussion,item.id)) } else { linking = true }
                    }
                }
                    .disabled(discussionRunning || reader.currentBook?.graph.node(.init(.discussion,item.id)) == nil)
                if !embedded { ReadingToolButton(symbol:"xmark",label:"关闭 AI 对话") { if persist() { close() } } }
            }.padding(.horizontal,ReadingInterface.inset).padding(.vertical,8)
            Divider()
            ReaderDiscussionPanel(reader:reader,item:$item,bookID:draft.bookID,palette:palette,standalone:true,runningChanged:{ discussionRunning = $0 })
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(12) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(palette.paper).foregroundStyle(palette.ink).tint(palette.accent)
        .sheet(isPresented:$linking,onDismiss:finishConnection) {
            ReadingNodeLinks(reader:reader,source:.init(.discussion,item.id),palette:palette,connected:{ createdConnection = $0 })
        }
        .task {
            // The note editor being replaced may have just flushed its last
            // keystrokes. Reload before the independent panel starts editing.
            let latest = reader.noteForEditing(item,bookID:draft.bookID)
            item = latest; baseline = latest
        }
        .task(id:item) {
            guard item != baseline else { return }
            status = "正在保存…"
            do { try await Task.sleep(for:.milliseconds(650)) } catch { return }
            if !Task.isCancelled { persist() }
        }
        .onChange(of:scenePhase) { phase in if phase != .active { persist() } }
        .onDisappear { persist() }
    }
    private func finishConnection() {
        guard let edge = createdConnection else { return }
        createdConnection = nil
        reader.revealReadingConnection(edge,bookID:draft.bookID)
    }
    @discardableResult private func persist() -> Bool {
        guard item != baseline, !reader.isNoteRemoved(item.id,bookID:draft.bookID) else { return true }
        if reader.autosaveDiscussion(item,bookID:draft.bookID) {
            baseline = item; status = "已自动保存"; failure = nil; return true
        }
        do {
            try reader.keepTextDraft(item,bookID:draft.bookID)
            status = "已保留草稿"; failure = "自动保存暂未完成，修改已保留在本机。"; return true
        } catch { failure = "修改暂时无法保存，请保留当前页面并重试。"; return false }
    }
}

struct ReaderDiscussionPanel: View {
    @ObservedObject var reader: ReaderModel
    @Binding var item: ReaderAnnotation
    let bookID: UUID
    let palette: BookGraphPalette
    var standalone = false
    var runningChanged: (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var run = ReaderDiscussionRun()
    @State private var nearby = ""
    @State private var readingSources: [ReaderDiscussionSource] = []
    @State private var sourceFailure: String?
    @State private var sourceLoading = true
    @State private var settings = false
    @State private var lastDraft = Date.distantPast
    @State private var persistenceFailure: String?
    @State private var followLatest = true
    @State private var selectionExpanded = false
    @FocusState private var composerFocused: Bool
    private var discussion: ReaderDiscussion { item.discussion ?? ReaderDiscussion() }
    private var composer: Binding<String> { Binding(get:{ discussion.composer },set:{ value in change { $0.composer = value } }) }
    private var scope: String? { item.discussionScope }
    private var scopeChapter: ChapterItem? { reader.chapters.first { $0.discussionScope == scope } }
    private var related: [ReaderAnnotation] {
        // Only the reader's saved thoughts are reused; generated answers never
        // silently become evidence for a different discussion.
        if let scope {
            guard scope == ReaderDiscussion.bookScope || scopeChapter != nil else { return [] }
            return reader.readingDiscussionNotes(chapter:scopeChapter,through:reader.noteVisibilityProgress)
        }
        let annotations = reader.currentAnnotations
        let subjects = Set(item.entityIDs ?? [])
        let ids = reader.bookNotesIndex.relatedNotes(for:item,through:item.progress).map(\.id)
        let matching = annotations.filter { note in
            note.id != item.id && note.progress <= item.progress + 0.0001 && !subjects.isDisjoint(with:note.entityIDs ?? [])
        }
        var seen = Set<String>()
        return Array((matching + ids.compactMap { id in annotations.first { $0.id == id } })
            .filter { $0.discussionScope == nil && (!$0.note.isEmpty || !$0.quote.isEmpty) && seen.insert($0.id).inserted }.prefix(3))
    }
    private var owner: ReadingNode? { reader.discussionContentOwner(item.id,bookID:bookID) }
    private var nodeText: String {
        switch owner?.content {
        case .entity(let entity): return entity.note ?? item.note
        case .ink(let ink): return ink.text ?? ""
        default: return item.note
        }
    }
    private func appendExcerpt(_ excerpt: String) {
        guard reader.currentID == bookID else { return }
        let text = nodeText.isEmpty ? excerpt : nodeText + "\n\n" + excerpt
        switch owner?.content {
        case .entity(var entity):
            entity.note = text
            guard reader.saveKnowledgeEntity(entity,bookID:bookID) != nil else { persistenceFailure = reader.error; return }
        case .ink(let ink):
            guard var latest = reader.currentPageNotes.first(where:{ $0.id == ink.id }) else { return }
            latest.text = text
            guard reader.saveGraphInkMetadata(latest) else { persistenceFailure = reader.error; return }
        default:
            item.note = text
            persist()
        }
    }
    private var request: ReaderDiscussionRequest {
        var context = item
        context.note = nodeText
        if case .entity(let entity) = owner?.content { context.title = entity.name }
        if scope != nil {
            context.progress = reader.noteVisibilityProgress
            context.chapter = scopeChapter?.title ?? item.chapter
        }
        return ReaderDiscussionPrompt.build(title:reader.currentBook?.title ?? "",author:reader.currentBook?.author ?? "",
            annotation:context,nearby:nearby,related:related,readingSources:readingSources)
    }
    private var canRetry: Bool { discussion.messages.last?.role == .assistant && discussion.messages.last?.state != .complete }
    private var sendDisabled: Bool { sourceLoading || discussion.composer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || discussion.composer.count > 4000 }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if standalone {
                        HStack {
                            Text("选中的原文").font(.caption).foregroundStyle(palette.muted)
                            Spacer()
                            ReadingToolButton(symbol:"slider.horizontal.3",label:"AI 设置") { settings = true }
                        }
                        if !item.quote.isEmpty {
                            ReadingSourceCard(chapter:item.chapter,text:item.quote,lineLimit:selectionExpanded ? nil : 4,textID:"discussion-selected-text")
                            if item.quote.count > 120 { Button(selectionExpanded ? "收起选文" : "展开选文") { selectionExpanded.toggle() }.font(.caption) }
                        }
                    } else {
                        HStack(alignment:.top,spacing:8) {
                            if !item.quote.isEmpty {
                                ReadingSourceCard(chapter:item.chapter,text:item.quote,lineLimit:3)
                            } else {
                                if scope != nil { Text(scopeChapter?.title ?? item.chapter).font(.callout.weight(.medium)) }
                                Spacer()
                            }
                            ReadingToolButton(symbol:"slider.horizontal.3",label:"AI 设置") { settings = true }
                        }
                    }
                    DisclosureGroup("本次讨论的上下文") {
                        VStack(alignment:.leading,spacing:10) {
                            Text(reader.currentBook?.title ?? "").font(.caption.weight(.medium))
                            if scope != nil || item.sourceLocator != nil || item.cfi.hasPrefix("epubcfi(") {
                                Toggle(scope == nil ? "带入选文之前的附近正文" : "带入已读正文摘录",isOn:Binding(get:{discussion.includeNearby},set:{ value in change { $0.includeNearby = value } }))
                            }
                            Toggle("带入相关的已读笔记",isOn:Binding(get:{discussion.includeRelatedNotes},set:{ value in change { $0.includeRelatedNotes = value } }))
                            Text(scope != nil ? "发送前可查看已读正文摘录、最多 3 条已读笔记和最近 7 轮对话。" : "可带入选文及此前正文、最多 3 条相关笔记和最近 7 轮对话。").foregroundStyle(palette.muted)
                            if sourceLoading { ProgressView("正在读取上下文…") }
                            if let sourceFailure, discussion.includeNearby { Text(sourceFailure).foregroundStyle(palette.muted) }
                            if request.context.omittedTurns > 0 { Text("较早的 \(request.context.omittedTurns) 轮已省略，完整对话仍保留在笔记中。").foregroundStyle(palette.muted) }
                            ForEach(request.context.sources) { source in
                                VStack(alignment:.leading,spacing:4) {
                                    Text("[\(source.id)] \(source.label)\(source.truncated ? " · 已截取" : "")").fontWeight(.medium)
                                    Text(source.text).lineLimit(6).textSelection(.enabled)
                                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(palette.background,in:RoundedRectangle(cornerRadius:8))
                            }
                        }.font(.caption).padding(.top,8).disabled(run.running)
                    }.font(.callout)
                    ForEach(discussion.messages) { message in
                        VStack(alignment:.leading,spacing:8) {
                            Text(message.role == .user ? "我" : message.model.map { "AI · \($0)" } ?? "AI").font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                            if message.text.isEmpty && message.state == .streaming { ProgressView("正在思考…").font(.caption) }
                            else if !message.text.isEmpty { Text(.init(message.text)).font(.body).lineSpacing(5).textSelection(.enabled) }
                            if message.role == .assistant {
                                if message.state != .complete && message.state != .streaming { Text("回答未完成，已保留收到的内容").font(.caption).foregroundStyle(palette.muted) }
                                if !message.text.isEmpty {
                                    let excerpt = "AI 讨论摘记：\n" + message.text
                                    if nodeText.contains(excerpt) {
                                        Label(standalone ? "已存为笔记" : "已摘入我的笔记",systemImage:"checkmark").font(.caption).foregroundStyle(palette.muted)
                                    } else {
                                        Button {
                                            appendExcerpt(excerpt)
                                        } label: {
                                            Text(standalone ? "存为笔记" : "摘入我的笔记").font(.caption).frame(minHeight:44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(run.running)
                                    }
                                }
                                if let context = message.context {
                                    DisclosureGroup("回答依据") {
                                        ForEach(context.sources) { source in
                                            VStack(alignment:.leading,spacing:4) {
                                                Text("[\(source.id)] \(source.label)").fontWeight(.medium)
                                                Text(source.text).textSelection(.enabled)
                                            }.padding(.vertical,6)
                                        }
                                        if context.omittedTurns > 0 { Text("省略了较早的 \(context.omittedTurns) 轮对话。") }
                                    }.font(.caption).foregroundStyle(palette.muted)
                                }
                            }
                        }.modifier(ReadingCardSurface(emphasized:message.role == .user))
                            .id(message.id)
                    }
                    Color.clear.frame(height:1).id("discussion-latest")
                }.padding(.horizontal,20).padding(.vertical,12)
                    .frame(maxWidth:700).frame(maxWidth:.infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance:12).onChanged { _ in followLatest = false })
            .safeAreaInset(edge:.bottom,spacing:0) { inputArea }
            .onAppear {
                if let id = reader.discussionFocusMessage { followLatest = false; proxy.scrollTo(id,anchor:.center) }
            }
            .onChange(of:reader.discussionFocusMessage) { id in
                if let id { followLatest = false; proxy.scrollTo(id,anchor:.center) }
            }
            .onChange(of:discussion.messages.count) { _ in
                followLatest = true
                proxy.scrollTo("discussion-latest",anchor:.bottom)
            }
            .onChange(of:discussion.messages.last?.text) { _ in
                if run.running && followLatest { proxy.scrollTo("discussion-latest",anchor:.bottom) }
            }
            .overlay(alignment:.bottomTrailing) {
                if !followLatest && run.running {
                    Button { followLatest = true; proxy.scrollTo("discussion-latest",anchor:.bottom) } label: {
                        Label("最新回答",systemImage:"arrow.down").font(.caption).padding(10)
                    }.buttonStyle(.bordered).background(palette.paper,in:Capsule()).padding(12)
                }
            }
        }
        .task(id:item.id) {
            // A process exit may leave a streaming marker in a durable draft.
            if discussion.messages.contains(where:{ $0.state == .streaming }) {
                change { value in for i in value.messages.indices where value.messages[i].state == .streaming { value.messages[i].state = .interrupted } }
            }
            sourceLoading = true
            defer { if !Task.isCancelled { sourceLoading = false } }
            do {
                if let scope {
                    if scope == ReaderDiscussion.bookScope || scopeChapter != nil {
                        readingSources = try await reader.readingDiscussionSources(bookID:bookID,chapter:scopeChapter)
                    }
                }
                else if !item.readingLocator.isEmpty { nearby = try await reader.discussionSource(locator:item.readingLocator) }
            } catch { if !Task.isCancelled { sourceFailure = "正文摘录暂时不可用，仍可使用现有材料提问。" } }
        }
        .onDisappear { run.stop(); persist(); runningChanged(false) }
        .onChange(of:run.running) { runningChanged($0) }
        .onChange(of:scenePhase) { phase in if phase == .background { run.stop() } }
        .sheet(isPresented:$settings) {
            ReaderDiscussionSettings()
            #if os(iOS)
                .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
            #endif
        }
    }
    private var inputArea: some View {
        VStack(alignment:.leading,spacing:8) {
            Divider()
            if let failure = persistenceFailure ?? run.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if canRetry && !run.running {
                Button("重试上一条问题") { send(retry:true) }.font(.callout).buttonStyle(.bordered)
            }
            ZStack(alignment:.topLeading) {
                if discussion.composer.isEmpty { Text("输入问题…").foregroundStyle(palette.muted).padding(10).allowsHitTesting(false) }
                TextEditor(text:composer).font(.body).scrollContentBackground(.hidden).padding(4)
                    .focused($composerFocused).accessibilityLabel("讨论问题").accessibilityIdentifier("discussion-composer")
            }.frame(height:64).background(palette.field,in:RoundedRectangle(cornerRadius:ReadingInterface.radius)).disabled(run.running)
            HStack(spacing:8) {
                Text("Codex Luna 优先").font(.caption2).foregroundStyle(palette.muted)
                Spacer(minLength:0)
                if run.running {
                    Button("停止") { run.stop() }.buttonStyle(.bordered).frame(minHeight:44)
                } else {
                    Button("发送") { send() }.modifier(ReadingPrimaryAction()).frame(minHeight:44)
                        .keyboardShortcut(.return,modifiers:.command)
                        .accessibilityIdentifier("discussion-send")
                        .disabled(sendDisabled)
                }
            }
            if discussion.composer.count > 4000 { Text("问题请控制在 4000 字以内。").font(.caption).foregroundStyle(palette.muted) }
        }.padding(.horizontal,20).padding(.bottom,8)
            .frame(maxWidth:700).frame(maxWidth:.infinity).background(palette.paper)
    }
    private func change(_ update: (inout ReaderDiscussion) -> Void) {
        var value = discussion; update(&value); item.discussion = value
    }
    @discardableResult private func persist() -> Bool {
        guard !reader.isNoteRemoved(item.id,bookID:bookID) else { return true }
        if reader.autosaveDiscussion(item,bookID:bookID) {
            persistenceFailure = nil; lastDraft = Date(); return true
        }
        do {
            try reader.keepTextDraft(item,bookID:bookID); lastDraft = Date()
            persistenceFailure = "自动保存暂未完成，对话已保留为本机草稿。"; return true
        } catch { persistenceFailure = "对话未能保存，请保留当前页面并重试。"; return false }
    }
    private func send(retry: Bool = false) {
        guard !run.running, !sourceLoading, reader.currentID == bookID else { return }
        composerFocused = false; followLatest = true
        var value = discussion
        if retry {
            guard canRetry else { return }; value.messages.removeLast()
        } else {
            let text = value.composer.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 4000 else { return }
            value.messages.append(.init(role:.user,text:text)); value.composer = ""
        }
        item.discussion = value
        let request = self.request
        var answer = ReaderDiscussionMessage(role:.assistant,text:"",state:.streaming)
        answer.context = request.context
        change { $0.messages.append(answer) }
        guard persist() else {
            change { $0.messages[$0.messages.count-1].state = .failed }; return
        }
        run.start(service:ReaderDiscussionCredentials.service(),requests:[request]) { text,state,model in
            change { value in
                guard let index = value.messages.firstIndex(where:{ $0.id == answer.id }) else { return }
                value.messages[index].text = text; value.messages[index].state = state; value.messages[index].model = model
            }
            if state != .streaming || Date().timeIntervalSince(lastDraft) >= 0.65 { persist() }
        }
    }
}

struct ReaderDiscussionSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var bridge = ""
    @State private var token = ""
    @State private var failure: String?
    @State private var loaded = false
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("AI 设置").font(.headline); Spacer(); Button("取消") { dismiss() } }
            Text("Codex Luna").font(.title3)
            #if os(macOS)
            Text("默认使用这台 Mac 上已登录的 Codex。填写桥接地址可改用桥接。")
                .font(.callout).foregroundStyle(.secondary)
            #else
            Text("填入运行 Codex Luna 的 Mac 桥接地址和令牌。")
                .font(.callout).foregroundStyle(.secondary)
            #endif
            TextField("Codex Luna 桥接地址",text:$bridge).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Codex Luna 桥接地址")
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
            SecureField("Codex Luna 桥接令牌",text:$token).textFieldStyle(.roundedBorder)
            Text("备用 DeepSeek V4.1 Flash").font(.headline)
            SecureField("DeepSeek API Key",text:$key).textFieldStyle(.roundedBorder).accessibilityLabel("DeepSeek API Key")
            Text("Luna 连不上或服务暂时不可用时，应用会将本次请求交给已配置的 DeepSeek。密钥和令牌保存在本机钥匙串。").font(.callout).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("保存设置") {
                let address = bridge.trimmingCharacters(in:.whitespacesAndNewlines)
                let credential = token.trimmingCharacters(in:.whitespacesAndNewlines)
                if !address.isEmpty {
                    guard let endpoint = ReaderDiscussionCredentials.bridgeURL(address) else {
                        failure = "请填写完整的 HTTPS 桥接地址。"; return
                    }
                    if endpoint.scheme == "https" && credential.isEmpty {
                        failure = "请输入 HTTPS 桥接的访问令牌。"; return
                    }
                }
                do {
                    try ReaderDiscussionCredentials.save(credential,luna:true)
                    try ReaderDiscussionCredentials.save(key)
                    UserDefaults.standard.set(address,forKey:ReaderDiscussionCredentials.bridgeSetting)
                    dismiss()
                }
                catch { failure = error.localizedDescription }
            }.buttonStyle(.borderedProminent).foregroundStyle(loaded ? Color.white : Color.secondary).disabled(!loaded) }
        }.padding(24).frame(minWidth:300,idealWidth:430)
        }.frame(idealHeight:420)
        .onAppear {
            do {
                key = try ReaderDiscussionCredentials.load()
                token = try ReaderDiscussionCredentials.load(luna:true)
                bridge = UserDefaults.standard.string(forKey:ReaderDiscussionCredentials.bridgeSetting) ?? ""
                loaded = true
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct ReaderTranslationPanel: View {
    let passage: String
    let palette: BookGraphPalette
    let close: () -> Void
    @StateObject private var run = ReaderDiscussionRun()
    @State private var language = "简体中文"
    @State private var translatedLanguage = ""
    @State private var result = ""
    @State private var provider: String?
    @State private var state: ReaderDiscussionMessage.State?
    @State private var settings = false
    @State private var showFullPassage = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    private let languages = ["简体中文","繁體中文","English","日本語","한국어","Français","Deutsch","Español"]

    var body: some View {
        VStack(spacing:0) {
            HStack {
                Label("AI 翻译",systemImage:"translate").font(.headline)
                Spacer()
                ReadingToolButton(symbol:"slider.horizontal.3",label:"AI 设置") { settings = true }
                ReadingToolButton(symbol:"xmark",label:"关闭 AI 翻译",action:close)
            }.padding(.horizontal,20).padding(.vertical,6)
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 680 {
                    HStack(spacing:0) {
                        ScrollView { original(full:true).padding(22) }
                            .frame(maxWidth:.infinity)
                        Divider()
                        ScrollView { translation.padding(22) }
                            .frame(maxWidth:.infinity)
                    }
                } else {
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            VStack(alignment:.leading,spacing:4) {
                                original(full:showFullPassage || typeSize.isAccessibilitySize)
                                if !typeSize.isAccessibilitySize && (passage.count > 60 || passage.filter(\.isNewline).count > 3) {
                                    Button(showFullPassage ? "收起原文" : "展开原文") { showFullPassage.toggle() }
                                        .font(.callout).frame(minHeight:44).foregroundStyle(palette.accent)
                                }
                            }.padding(14)
                                .background(palette.background,in:RoundedRectangle(cornerRadius:ReadingInterface.radius))
                            translation
                        }.padding(20)
                    }
                }
            }
            Divider()
            HStack {
                Picker("译成",selection:$language) { ForEach(languages,id:\.self) { Text($0).tag($0) } }
                    .pickerStyle(.menu).frame(minHeight:44).disabled(run.running)
                Spacer()
                if run.running { Button("停止") { run.stop() }.buttonStyle(.bordered).frame(minHeight:44) }
                else { Button(state == nil ? "翻译" : "重新翻译",action:translate).modifier(ReadingPrimaryAction()).frame(minHeight:44) }
            }.padding(16)
        }.background(palette.paper).foregroundStyle(palette.ink).tint(palette.accent)
        #if os(macOS)
        .frame(minWidth:450,idealWidth:520,minHeight:330,idealHeight:500)
        #endif
        .sheet(isPresented:$settings) { ReaderDiscussionSettings() }
        .onDisappear { run.stop() }
        .onChange(of:scenePhase) { phase in if phase == .background { run.stop() } }
    }

    private func original(full: Bool) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text("原文").font(.subheadline.weight(.semibold))
            Text(passage).font(.body).lineSpacing(5).lineLimit(full ? nil : 4).textSelection(.enabled)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private var translation: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("译文").font(.subheadline.weight(.semibold))
            if let provider { Text("\(translatedLanguage) · \(provider)").font(.caption).foregroundStyle(palette.accent) }
            if run.running && result.isEmpty { ProgressView("正在翻译…") }
            if !result.isEmpty { Text(result).font(.body).textSelection(.enabled).lineSpacing(5) }
            if state == .failed || state == .interrupted, !result.isEmpty {
                Text("译文未完成").font(.caption).foregroundStyle(.secondary)
            }
            if let error = run.failure { Text(error).font(.callout).foregroundStyle(.red) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private func translate() {
        result = ""; provider = nil; state = nil
        translatedLanguage = language
        let requests = ReaderDiscussionPrompt.translationPassages(passage).map { ReaderDiscussionPrompt.translation($0,into:language) }
        run.start(service:ReaderDiscussionCredentials.service(),requests:requests) { text,status,model in
            result = text; state = status; provider = model
        }
    }
}

extension ReaderModel {
    func readingDiscussionNotes(chapter: ChapterItem?,through progress: Double) -> [ReaderAnnotation] {
        let structure = bookNotesIndex.structure
        let chapterID = chapter.flatMap { chapter in
            chapters.firstIndex { $0.id == chapter.id && $0.href == chapter.href }
        }
        var seen = Set<String>()
        let matches = currentAnnotations.reversed().filter { note in
            guard note.discussionScope == nil, note.progress <= progress + 0.0001, !note.note.isEmpty || !note.quote.isEmpty else { return false }
            guard let chapter else { return true }
            guard let chapterID, let noteSection = structure.sectionID(href:note.chapterHref,title:note.chapter) else {
                return note.chapterHref == chapter.href || (note.chapterHref == nil && note.chapter == chapter.title)
            }
            return noteSection == chapterID || structure.ancestors(of:noteSection).contains(chapterID)
        }
        let distinct = matches.filter { seen.insert($0.chapterHref ?? $0.chapter).inserted }
        let identifiers = Set(distinct.map(\.id))
        return Array((distinct + matches.filter { !identifiers.contains($0.id) }).prefix(3))
    }

    @MainActor func readingDiscussionSources(bookID: UUID,chapter: ChapterItem?) async throws -> [ReaderDiscussionSource] {
        guard currentID == bookID, let book = currentBook else { return [] }
        let session = annotationSessionID
        let locator = position?.locator ?? book.locator
        guard !locator.isEmpty else { return [] }
        let start = chapter?.href ?? ""
        let end = chapter.flatMap { chapter in
            guard let i = chapters.firstIndex(where:{ $0.id == chapter.id }) else { return nil as String? }
            return chapters.dropFirst(i+1).first { $0.depth <= chapter.depth && $0.href != start }?.href
        } ?? ""
        let excerpts: [String]
        if let pdf = pdfBookReader {
            excerpts = pdf.readingDiscussionExcerpts(through:locator,from:start,until:end)
        } else {
            let value = try await webView.callAsyncJavaScript("return await reader.readingDiscussionExcerpts(locator,start,end)",
                arguments:["locator":locator,"start":start,"end":end],in:nil,contentWorld:.page)
            excerpts = value as? [String] ?? []
        }
        guard !Task.isCancelled, currentID == bookID, annotationSessionID == session else { throw CancellationError() }
        return excerpts.enumerated().map { i,text in
            .init(id:"已读正文\(i+1)",label:chapter?.title ?? "已读正文摘录",text:text,limit:1500)
        }
    }

    @discardableResult func autosaveDiscussion(_ item: ReaderAnnotation,bookID: UUID) -> Bool {
        let discussion = item.discussion ?? ReaderDiscussion()
        let existing = books.first(where:{ $0.id == bookID })?.annotations?.contains(where:{ $0.id == item.id }) == true
        // Opening a menu or a discussion is not itself a new note/highlight.
        if !existing && item.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && discussion.messages.isEmpty && discussion.composer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            if let id = UUID(uuidString:item.id) {
                do { try discardNoteDraft(bookID:bookID,id:id,ink:false) }
                catch { self.error = "未发送的问题暂时无法清理，请重试。"; return false }
            }
            return true
        }
        return autosaveGraphAnnotation(item,bookID:bookID,relation:item.graphRelationDraft)
    }
    @MainActor func discussionSource(locator: String) async throws -> String {
        if let nativeBookReader { return nativeBookReader.precedingText(at:locator) }
        let session = annotationSessionID
        let value = try await webView.callAsyncJavaScript("return await reader.discussionExcerpt(locator)",arguments:["locator":locator],in:nil,contentWorld:.page)
        guard annotationSessionID == session, currentID != nil else { throw CancellationError() }
        return value as? String ?? ""
    }
}
