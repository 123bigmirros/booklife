import SwiftUI
import AppKit
import SystemConfiguration
#if canImport(BookSlideCore)
import BookSlideCore
#endif
#if canImport(BookSlideTerminal)
import BookSlideTerminal
#endif
#if canImport(BookSlideTransport)
import BookSlideTransport
#endif

final class ReceiverModel: ObservableObject {
    @Published var state = "尚未启动"
    @Published var lastCommand = "打开一本书，手表会自动就绪"
    @Published var enabled = !UserDefaults.standard.bool(forKey:"macRemotePaused")
    private var retryAfter = Date.distantPast
    @Published var bluetoothState = "正在准备蓝牙…"
    @Published var running = false
    @Published var pairingOpen = false
    @Published var pending: PairingCoordinator.Pending?
    @Published var pairingMessage = "Apple Watch 可直接通过蓝牙连接这台 Mac。首次添加手表，以后开书即用。"
    private let reader: ReaderModel
    private var token = ""
    private var port: UInt16 = 8765
    private var server: HTTPServer?
    private var bluetooth: BluetoothReceiver?
    private var requestHandler: ((HTTPRequest) async -> HTTPResponse)?
    private var timer: Timer?
    private let receiverID: UUID
    let receiverName = String((Host.current().localizedName ?? "我的 Mac").prefix(60))
    private lazy var pairing = PairingCoordinator(receiverID: receiverID) { [weak self] in self?.connection }
    private var connection: SavedConnection? {
        guard !token.isEmpty else { return nil }
        let host = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "bookslide"
        return SavedConnection(receiverID: receiverID,name:receiverName,endpoint:"http://\(host).local:\(port)",token:token)
    }
    init(reader: ReaderModel, startAutomatically: Bool = true) {
        self.reader = reader
        receiverID = startAutomatically ? (UserDefaults.standard.string(forKey:"localReceiverID").flatMap(UUID.init(uuidString:)) ?? UUID()) : UUID()
        guard startAutomatically else { enabled = false; return }
        UserDefaults.standard.set(receiverID.uuidString,forKey:"localReceiverID")
        // A development-signature update can make Keychain wait for the user.
        // Keep the reader responsive while the existing credential is opened.
        Task { @MainActor [weak self] in
            do {
                let savedToken = try await Task.detached(priority:.userInitiated) {
                    let value = try PairingStore.load() ?? PairingStore.generate()
                    try PairingStore.save(value)
                    return value
                }.value
                guard let self else { return }
                self.token = savedToken
                if self.enabled { self.start() }
            } catch { self?.state = "无法读取连接凭据：\(error.localizedDescription)" }
        }
        pairing.onChange = { [weak self] in
            guard let self else { return }; self.pairingOpen = self.pairing.isOpen; self.pending = self.pairing.pending
        }
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.pairing.expire()
            if self.enabled, self.server == nil, Date() >= self.retryAfter { self.start() }
        }
    }
    func start() {
        enabled = true; UserDefaults.standard.set(false,forKey:"macRemotePaused")
        guard !token.isEmpty, server == nil else { return }
        let router = ReadingRouter(token:token,snapshot:{ [weak reader] in reader?.snapshot },readiness:{ [weak reader] in
            guard let reader, !reader.loading, reader.snapshot != nil else { return "请先在 Mac 打开一本书" }
            guard let window = reader.readingWindow, window.isVisible, !window.isMiniaturized else {
                return "请展开 Mac 的书籍人生阅读窗口"
            }
            return nil
        },turn:{ [weak reader] direction in
            guard let reader else { return "阅读器已关闭" }
            return await reader.turn(direction)
        },scroll:{ [weak reader] direction,lines in
            guard let reader else { return "阅读器已关闭" }
            return await reader.turn(direction,scrollLines:lines)
        })
        let bridge = TerminalBridge(token:token)
        let progress = ProgressRouter(token:token,store:reader.progressStore)
        let library = LibraryRouter(token:token,catalog:{ [weak reader] in reader?.sharedCatalog() ?? [] },archive:{ [weak reader] id in
            guard let reader, let book = reader.books.first(where: { $0.id == id }), let format = book.format else { throw CocoaError(.fileNoSuchFile) }
            let file = book.sourcePath.map { URL(fileURLWithPath:$0) } ?? reader.directory.appendingPathComponent(book.filename)
            return try await Task.detached(priority:.userInitiated) { try ReaderModel.bookData(at:file, format:format) }.value
        })
        let handle: (HTTPRequest) async -> HTTPResponse = requestHandler ?? { [weak self] request in
            if let result = self?.pairing.handle(request) { return result }
            if let result = progress.handle(request) { return result }
            if let response = await library.handle(request) { return response }
            let response: HTTPResponse
            if let forwarded = await bridge.handle(request) { response = forwarded }
            else { response = await router.handle(request) }
            if request.path == "/v3/turn", RequestAuthentication.verify(request,token:router.token) {
                self?.lastCommand = response.reply.message
                NSLog("BookSlide Mac reply %@ ok=%d", response.reply.commandID?.uuidString ?? "unknown", response.reply.ok)
            }
            return response
        }
        requestHandler = handle
        if bluetooth == nil {
            let direct = BluetoothReceiver(handler: handle)
            direct.onState = { [weak self] in self?.bluetoothState = $0 }
            bluetooth = direct; direct.start(name: receiverName)
        }
        let server = HTTPServer(handler: handle)
        server.onState = { [weak self] message, port in
            guard let self else { return }
            self.state = message; self.running = port != nil
            if let port { self.port = port }
            else if message.hasPrefix("启动失败") { self.server = nil; self.retryAfter = Date().addingTimeInterval(5) }
        }
        self.server = server
        do { try server.start(serviceName:receiverName,receiverID:receiverID) }
        catch { state = error.localizedDescription; self.server = nil; retryAfter = Date().addingTimeInterval(5) }
    }
    func stop() { enabled = false; UserDefaults.standard.set(true,forKey:"macRemotePaused"); reader.invalidateSession(); pairing.clear(); bluetooth?.stop(); bluetooth = nil; requestHandler = nil; server?.stop(); server = nil; running = false; state = "已停止接收" }
    func beginPairing() { start(); guard bluetooth != nil else { return }; pairing.begin() }
    func approve(_ id: UUID) {
        if pairing.approve(id:id) {
            UserDefaults.standard.set(true,forKey:"hasPairedDevice")
            pairingMessage = "已配对。现在打开一本书，手表会自动连接。"
        }
    }
    func reject() { pairing.clear() }
}

@main
struct BookSlideMacApp: App {
    @StateObject private var reader: ReaderModel
    @StateObject private var receiver: ReceiverModel
    private let previewWorkspace: Bool
    init() {
        // A separate debug preview bundle can exercise editing and recovery
        // without touching the user's library, progress, pairing or receiver.
        #if DEBUG
        let previewDirectory = Bundle.main.object(forInfoDictionaryKey:"BookSlidePreviewLibrary") as? String
        previewWorkspace = Bundle.main.object(forInfoDictionaryKey:"BookSlidePreviewWorkspace") as? Bool ?? false
        #else
        let previewDirectory: String? = nil
        previewWorkspace = false
        #endif
        let reader = previewDirectory.map { ReaderModel(directory:URL(fileURLWithPath:$0),loadExternalSources:false) } ?? ReaderModel()
        _reader = StateObject(wrappedValue:reader)
        _receiver = StateObject(wrappedValue:ReceiverModel(reader:reader,startAutomatically:previewDirectory == nil))
    }
    var body: some Scene {
        Window("书籍人生",id:"reader") {
            ZStack {
                // Keep WebKit mounted at the same size: removing it from the
                // window triggers EPUB reflow and can corrupt the saved position.
                ReaderWindow(reader:reader,receiver:receiver)
                    .opacity(reader.showNoteGraph ? 0 : 1)
                    .allowsHitTesting(!reader.showNoteGraph)
                    .accessibilityHidden(reader.showNoteGraph)
                if reader.showNoteGraph {
                    BookNotesWorkspace(reader:reader) { reader.showNoteGraph = false }
                        .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
                        .frame(minWidth:1050,minHeight:720)
                        .onDisappear { reader.annotationDraft = nil; reader.graphNoteID = nil }
                }
            }
            .sheet(item:$reader.selectionDiscussion) { draft in
                ReaderSelectionDiscussion(reader:reader,draft:draft) { reader.selectionDiscussion = nil }
                    .frame(width:480,height:680)
                    .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
            }
            .sheet(item:$reader.selectionEntity) { draft in
                ReadingEntityFromSelection(reader:reader,draft:draft)
            }
            .onOpenURL { reader.importBooks([$0]) }
            .task {
                if previewWorkspace, reader.currentID == nil, let id = reader.books.first?.id {
                    reader.open(id)
                    for _ in 0..<150 {
                        if !reader.loading && reader.position != nil { break }
                        try? await Task.sleep(for:.milliseconds(100))
                    }
                    reader.openNoteGraph(noteID:reader.currentAnnotations.first(where: { $0.chapter == reader.position?.chapter })?.id)
                }
            }
        }
        .defaultSize(width:previewWorkspace ? 1440 : 1120,height:previewWorkspace ? 1024 : 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing:.newItem) { Button("导入书籍…") { reader.chooseImport() }.keyboardShortcut("o") }
            CommandMenu("阅读") {
                Button("全书脉络与笔记") { reader.openKnowledgeWorkspace() }.keyboardShortcut("n",modifiers:[.command,.shift])
                Divider()
                Button("继续阅读") {
                    if let book = reader.visibleBooks.sorted(by: { $0.lastRead > $1.lastRead }).first { reader.open(book.id) }
                }.keyboardShortcut("r").disabled(reader.currentID != nil || reader.visibleBooks.isEmpty)
                Button(reader.readingMode.nextLabel) { Task { @MainActor in await reader.turnLocally(.next) } }.keyboardShortcut(.rightArrow,modifiers:[]).disabled(reader.snapshot == nil)
                Button(reader.readingMode.previousLabel) { Task { @MainActor in await reader.turnLocally(.previous) } }.keyboardShortcut(.leftArrow,modifiers:[]).disabled(reader.snapshot == nil)
                Button(reader.isScrolling ? "向下滚动一屏" : "向下翻页") { Task { @MainActor in await reader.turnLocally(.next) } }.keyboardShortcut(.downArrow,modifiers:[]).disabled(reader.snapshot == nil)
                Button(reader.isScrolling ? "向上滚动一屏" : "向上翻页") { Task { @MainActor in await reader.turnLocally(.previous) } }.keyboardShortcut(.upArrow,modifiers:[]).disabled(reader.snapshot == nil)
                Divider()
                Button("添加 / 移除书签") { reader.toggleBookmark() }.keyboardShortcut("d").disabled(reader.snapshot == nil)
                Button("返回书架") { reader.close() }.keyboardShortcut("l")
            }
        }
    }
}
