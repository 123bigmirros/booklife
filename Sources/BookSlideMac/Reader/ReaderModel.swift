#if os(macOS)
import AppKit
typealias ReaderImage = NSImage
#else
import UIKit
typealias ReaderImage = UIImage
#endif
import SwiftUI
import WebKit
import CryptoKit
import UniformTypeIdentifiers
#if canImport(BookSlideCore)
import BookSlideCore
#endif
#if os(macOS) && canImport(BookSlideTerminal)
import BookSlideTerminal
#endif

struct ReaderBookmark: Codable, Identifiable {
    var id: String // Stable locator supplied by the reading engine.
    var title: String
    var progress: Double
    var viewport: ReaderViewport? = nil
}
/// A content anchor plus its placement in one typography/viewport. Pixel
/// offsets are only reused for the same layout; CFI remains the fallback.
struct ReaderViewport: Codable {
    struct Point: Codable { var x: Double; var y: Double }
    var positionLocator: String? = nil
    var locator: String
    var point: Point?
    var mode: ReadingMode
    var layoutKey: String
    var anchor: ContentAnchor?
}
struct LibraryBook: Codable, Identifiable {
    var id: UUID
    var title: String
    var author: String
    var filename: String
    var locator: String = ""
    var readingViewport: ReaderViewport?
    var progress: Double = 0
    var furthestReadProgress: Double?
    var lastRead: Date = Date()
    var bookmarks: [ReaderBookmark] = []
    // One persisted graph. These typed views keep the EPUB, ink and editor
    // adapters source-compatible while all writes update the same model.
    var graph = ReadingGraph()
    var annotations: [ReaderAnnotation]? {
        get { graph.annotations }
        set { graph.replaceAnnotations(newValue ?? []) }
    }
    var pageNotes: [ReaderPageNote]? {
        get { graph.pageNotes }
        set { graph.replacePageNotes(newValue ?? []) }
    }
    var removedNotes: [ReaderRemovedNote]? {
        get { graph.removals }
        set { graph.removals = newValue ?? [] }
    }
    var knowledgeEntities: [BookEntity]? {
        get { graph.entities }
        set { graph.replaceEntities(newValue ?? []) }
    }
    var knowledgeRelations: [BookRelation]? {
        get { graph.relations }
        set { graph.replaceRelations(newValue ?? []) }
    }
    var relationDrafts: [BookRelationDraft]? {
        get { graph.relationDrafts }
        set { graph.relationDrafts = newValue ?? [] }
    }
    var sourcePath: String?
    var remoteBookID: UUID?
    var remoteReceiverID: UUID?
    var progressKey: String?
    var contentHash: String?
    var hidden: Bool?
    var formatIdentifier: String?
    var prefersTextLayout: Bool?
    var format: BookFormat? {
        if !filename.isEmpty { return BookFormat(filename: filename) }
        if let sourcePath { return BookFormat(filename: sourcePath) }
        return BookFormat(rawValue: formatIdentifier ?? "epub")
    }
    var displayAuthor: String { author == format?.label ? "" : author }

    init(id: UUID, title: String, author: String, filename: String, locator: String = "", progress: Double = 0,
         furthestReadProgress: Double? = nil, lastRead: Date = Date(), bookmarks: [ReaderBookmark] = [],
         annotations: [ReaderAnnotation]? = nil, pageNotes: [ReaderPageNote]? = nil, removedNotes: [ReaderRemovedNote]? = nil,
         knowledgeEntities: [BookEntity]? = nil, knowledgeRelations: [BookRelation]? = nil, relationDrafts: [BookRelationDraft]? = nil,
         sourcePath: String? = nil, remoteBookID: UUID? = nil, remoteReceiverID: UUID? = nil, progressKey: String? = nil,
         contentHash: String? = nil, hidden: Bool? = nil) {
        self.id = id; self.title = title; self.author = author; self.filename = filename; self.locator = locator; self.progress = progress
        self.furthestReadProgress = furthestReadProgress; self.lastRead = lastRead; self.bookmarks = bookmarks
        graph = ReadingGraph(annotations:annotations ?? [],pageNotes:pageNotes ?? [],entities:knowledgeEntities ?? [],relations:knowledgeRelations ?? [])
        graph.removals = removedNotes ?? []; graph.relationDrafts = relationDrafts ?? []
        self.sourcePath = sourcePath; self.remoteBookID = remoteBookID; self.remoteReceiverID = remoteReceiverID
        self.progressKey = progressKey; self.contentHash = contentHash; self.hidden = hidden
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, author, filename, locator, readingViewport, progress, furthestReadProgress, lastRead, bookmarks, graph
        case annotations, pageNotes, removedNotes, knowledgeEntities, knowledgeRelations, relationDrafts
        case sourcePath, remoteBookID, remoteReceiverID, progressKey, contentHash, hidden, formatIdentifier, prefersTextLayout
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy:CodingKeys.self)
        id = try box.decode(UUID.self,forKey:.id); title = try box.decode(String.self,forKey:.title)
        author = try box.decode(String.self,forKey:.author); filename = try box.decode(String.self,forKey:.filename)
        locator = try box.decodeIfPresent(String.self,forKey:.locator) ?? ""; progress = try box.decodeIfPresent(Double.self,forKey:.progress) ?? 0
        readingViewport = try? box.decode(ReaderViewport.self,forKey:.readingViewport)
        furthestReadProgress = try box.decodeIfPresent(Double.self,forKey:.furthestReadProgress)
        lastRead = try box.decodeIfPresent(Date.self,forKey:.lastRead) ?? .distantPast; bookmarks = try box.decodeIfPresent([ReaderBookmark].self,forKey:.bookmarks) ?? []
        if box.contains(.graph) {
            graph = try box.decode(ReadingGraph.self,forKey:.graph)
        } else {
            graph = ReadingGraph(annotations:try box.decodeIfPresent([ReaderAnnotation].self,forKey:.annotations) ?? [],
                pageNotes:try box.decodeIfPresent([ReaderPageNote].self,forKey:.pageNotes) ?? [],
                entities:try box.decodeIfPresent([BookEntity].self,forKey:.knowledgeEntities) ?? [],
                relations:try box.decodeIfPresent([BookRelation].self,forKey:.knowledgeRelations) ?? [])
            graph.removals = try box.decodeIfPresent([ReaderRemovedNote].self,forKey:.removedNotes) ?? []
            graph.relationDrafts = try box.decodeIfPresent([BookRelationDraft].self,forKey:.relationDrafts) ?? []
        }
        sourcePath = try box.decodeIfPresent(String.self,forKey:.sourcePath); remoteBookID = try box.decodeIfPresent(UUID.self,forKey:.remoteBookID)
        remoteReceiverID = try box.decodeIfPresent(UUID.self,forKey:.remoteReceiverID); progressKey = try box.decodeIfPresent(String.self,forKey:.progressKey)
        prefersTextLayout = try box.decodeIfPresent(Bool.self,forKey:.prefersTextLayout)
        formatIdentifier = try box.decodeIfPresent(String.self,forKey:.formatIdentifier)
        contentHash = try box.decodeIfPresent(String.self,forKey:.contentHash); hidden = try box.decodeIfPresent(Bool.self,forKey:.hidden)
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy:CodingKeys.self)
        try box.encode(id,forKey:.id); try box.encode(title,forKey:.title); try box.encode(author,forKey:.author); try box.encode(filename,forKey:.filename)
        try box.encode(locator,forKey:.locator); try box.encode(progress,forKey:.progress); try box.encode(lastRead,forKey:.lastRead); try box.encode(bookmarks,forKey:.bookmarks)
        try box.encodeIfPresent(readingViewport,forKey:.readingViewport)
        try box.encode(graph,forKey:.graph)
        try box.encodeIfPresent(furthestReadProgress,forKey:.furthestReadProgress); try box.encodeIfPresent(sourcePath,forKey:.sourcePath)
        try box.encodeIfPresent(remoteBookID,forKey:.remoteBookID); try box.encodeIfPresent(remoteReceiverID,forKey:.remoteReceiverID)
        try box.encodeIfPresent(formatIdentifier,forKey:.formatIdentifier)
        try box.encodeIfPresent(prefersTextLayout,forKey:.prefersTextLayout)
        try box.encodeIfPresent(progressKey,forKey:.progressKey); try box.encodeIfPresent(contentHash,forKey:.contentHash); try box.encodeIfPresent(hidden,forKey:.hidden)
    }
}
struct ChapterItem: Codable, Identifiable {
    var id: String
    var href: String
    var title: String
    var depth: Int
}
struct EnginePosition: Codable {
    var viewport: ReaderViewport? = nil
    var session: String? = nil
    var chapterHref: String?
    var viewportOffset: Double?
    var anchor: ContentAnchor?
    var userDriven: Bool?
    var mode: ReadingMode
    var locator: String
    var chapter: String
    var page: Int
    var pageCount: Int
    var progress: Double
    var canGoNext: Bool
    var canGoPrevious: Bool
}
/// An sRGB swatch shared by SwiftUI and the embedded reading canvas.
struct ReaderSwatch {
    let rgb: UInt32
    init(_ rgb: UInt32) { self.rgb = rgb }
    private func channel(_ shift: Int) -> Double { Double((rgb >> shift) & 255) / 255 }
    var color: Color { Color(red:channel(16),green:channel(8),blue:channel(0)) }
    var css: String { String(format:"#%06X",rgb) }
    func mixed(with other: ReaderSwatch, fraction: Double) -> ReaderSwatch {
        func byte(_ shift: Int) -> UInt32 {
            UInt32(((channel(shift) * (1-fraction) + other.channel(shift) * fraction) * 255).rounded())
        }
        return ReaderSwatch(byte(16) << 16 | byte(8) << 8 | byte(0))
    }
}

struct ReaderAppearance: Codable, Equatable {
    var mode = ReadingMode.scroll
    var sideInset = 8.0
    var theme = "paper"
    var font = "sans"
    #if os(iOS)
    var fontSize = 20.0
    #else
    var fontSize = 26.0
    #endif
    var lineHeight = 1.75
    #if os(iOS)
    var margin = 32.0
    #else
    var margin = 64.0
    #endif
    var pageSwatch: ReaderSwatch {
        switch theme {
        case "night": ReaderSwatch(0x202725)
        case "light": ReaderSwatch(0xFFFFFF)
        default: ReaderSwatch(0xF2E3C8)
        }
    }
    var inkSwatch: ReaderSwatch {
        switch theme {
        case "night": ReaderSwatch(0xD9DFD8)
        case "light": ReaderSwatch(0x242824)
        default: ReaderSwatch(0x382D20)
        }
    }
    var background: Color { pageSwatch.color }
    var ink: Color { inkSwatch.color }
    init() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad { lineHeight = 1.65 }
        #endif
    }
    private enum CodingKeys: String, CodingKey { case sideInset, mode, theme, font, fontSize, lineHeight, margin }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy:CodingKeys.self)
        sideInset = min(30,max(0,try values.decodeIfPresent(Double.self,forKey:.sideInset) ?? sideInset))
        mode = try values.decodeIfPresent(ReadingMode.self,forKey:.mode) ?? .scroll
        theme = try values.decodeIfPresent(String.self,forKey:.theme) ?? theme
        font = try values.decodeIfPresent(String.self,forKey:.font) ?? font
        fontSize = try values.decodeIfPresent(Double.self,forKey:.fontSize) ?? fontSize
        lineHeight = try values.decodeIfPresent(Double.self,forKey:.lineHeight) ?? lineHeight
        margin = try values.decodeIfPresent(Double.self,forKey:.margin) ?? margin
    }
}

/// EPUB content and scripts are kept separate: only bundled reader scripts run.
final class ReaderModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    var cachedNotesIndex: BookNotesIndex?
    var cachedNoteRecordProgress: Double?
    private(set) var notesIndexBuildCount = 0
    func recordNotesIndexBuild() { notesIndexBuildCount += 1 }
    @Published private(set) var nativeBookReader: NativeBookReader?
    @Published var nativeSelection: ReaderAnnotation?
    @Published private(set) var pdfTextRecognitionRunning = false
    @Published var nativeSelectionGeneration = UUID()
    @Published var pdfTextTarget: NSRange?
    var isPDFTextLayout: Bool { pdfBookReader != nil && currentBook?.prefersTextLayout == true }
    var pdfBookReader: PDFBookReader? { nativeBookReader as? PDFBookReader }
    private var nativeSearchTask: Task<Void,Never>?
    @Published var coverRevision = 0
    @Published var books: [LibraryBook] = [] { didSet { cachedNotesIndex = nil; cachedNoteRecordProgress = nil } }
    @Published var currentID: UUID? { didSet { cachedNotesIndex = nil; cachedNoteRecordProgress = nil; selectedReadingItem = nil; discussionFocusMessage = nil; selectionDiscussion = nil } }
    @Published var selectedReadingItem: ReadingGraphSelection?
    @Published var discussionFocusMessage: UUID?
    @Published var position: EnginePosition?
    @Published var chapters: [ChapterItem] = [] { didSet { cachedNotesIndex = nil; cachedNoteRecordProgress = nil } }
    @Published var results: [ChapterItem] = []
    @Published var loading = false
    @Published var searchState = ReaderSearchState.idle
    var searching: Bool { searchState == .searching }
    @Published var importingBooks = false
    @Published var importMessage: String?
    @Published private var navigationBusy = false
    @Published private var appearancePending = false
    var busy: Bool {
        get { navigationBusy || appearancePending }
        set { navigationBusy = newValue }
    }
    @Published var pageTurnVisual: ReaderPageTurn?
    @Published var error: String?
    @Published var readingNotice: String?
    @Published var needsAppleBooksFolder = false
    @Published var syncingLibrary = false
    @Published var downloadingBook: UUID?
    @Published var downloadProgress = 0.0
    @Published var readingControlsVisible = false
    @Published var locationsReady = false
    @Published var annotationDraft: ReaderAnnotationDraft? { didSet { cachedNotesIndex = nil; cachedNoteRecordProgress = nil } }
    @Published var quickNoteDraft: ReaderAnnotationDraft?
    @Published var showNoteGraph = false
    @Published var knowledgeCanvasExpanded = false
    @Published var openingLibraryNote: String?
    @Published var graphNoteID: String?
    @Published var discussionNoteID: String?
    @Published var selectionDiscussion: ReaderAnnotationDraft?
    @Published var selectionEntity: ReaderAnnotationDraft?
    var pendingGraphNote: (bookID: UUID, noteID: String)?
    var knowledgeOpenTask: Task<Void,Never>?
    var readingSelectionTask: Task<Void,Never>?
    @Published var textNoteDrafts: [ReaderTextNoteDraft] = [] { didSet { cachedNotesIndex = nil; cachedNoteRecordProgress = nil } }
    @Published var inkNoteDrafts: [ReaderInkNoteDraft] = []
    @Published var readingNodeDrafts: [ReadingNodeDraft] = []
    @Published var noteUndoID: UUID?
    @Published var pageNoteToView: ReaderPageNote?
    @Published var visiblePageNoteIDs: [UUID] = []
    @Published var hiddenPageNoteIDs: [UUID] = []
    @Published var handwritingActive = false
    #if os(iOS)
    var mindMapInputFlush: (id: UUID,perform: () async -> Bool)?
    @Published var inlineInkToolsVisible = false
    @Published var inlineInkTool: ReaderInkTool = .reading
    @Published var inlineInkColor: ReaderInkColor = .ink
    @Published var inlineInkWidth: CGFloat = 3
    @Published var inlineInkCanUndo = false
    @Published var inlineInkCanRedo = false
    @Published var inlineInkSelectionActive = false
    @Published var inlineInkMenuActive = false
    @Published var inlineInkStatus: String?
    var inlineInkObscured = false
    weak var inlineInk: ReaderInlineInkController?
    #endif
    var annotationSessionID = UUID()
    private var openTask: Task<Void,Never>?
    @Published var libraryMessage: String?
    var libraryRefreshPending = false
    private var noticeWork: DispatchWorkItem?
    @Published var appearance = ReaderAppearance()
    private var acceptedAppearance = ReaderAppearance()
    private(set) var sessionID = UUID()
    // Remote requests expire independently of an EPUB open/reflow/turn. A
    // background pause must not orphan the native operation holding its lock.
    private var controlSessionID = UUID()
    var onReadingChanged: (() -> Void)?
    private var engineReady = false
    private var libraryLoaded = false
    var allowsLibraryWrites: Bool { libraryLoaded }
    private var fontSent = false
    private var pendingBook: UUID?
    private var saveWork: DispatchWorkItem?
    private var appearanceWork: DispatchWorkItem?
    private var searchGeneration = UUID()
    let directory: URL
    let externalSourcesEnabled: Bool
    let progressStore: ProgressStore
    @Published var progressStatus = "进度已保存在本机"
    @Published var pendingProgress: ReadingProgress?
    @Published var showProgressSettings = false
    @Published var syncingProgress = false
    @Published var cloudSyncConfigured = false
    @Published var cloudFolderName: String?
    var appliedProgressID: UUID?
    var dismissedProgressID: UUID?
    var lastRecordedLocator: String?
    var progressTimer: Timer?
    var restoringProgress = false
    lazy var progressDeviceID: UUID = (try? progressStore.deviceID(source:progressSource)) ?? UUID()
    var progressSource: String {
        #if os(macOS)
        return "mac"
        #else
        return "phone"
        #endif
    }
    var progressDeviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
    var visibleBooks: [LibraryBook] { books.filter { $0.hidden != true } }
    var sampleBook: LibraryBook? { visibleBooks.first { $0.title == "留一点时间，给阅读" && ($0.author.hasPrefix("书籍人生") || $0.author.hasPrefix("页枝") || $0.author.hasPrefix("BookSlide")) } }
    var hasHiddenBooks: Bool { books.contains { $0.hidden == true } || !(UserDefaults.standard.stringArray(forKey:"hiddenAppleBooks") ?? []).isEmpty || !(UserDefaults.standard.stringArray(forKey:"hiddenRemoteBooks") ?? []).isEmpty }
    var currentBook: LibraryBook? { books.first { $0.id == currentID } }
    var supportsReflow: Bool { currentBook?.format == .epub }
    var readingMode: ReadingMode { appearance.mode }
    var isScrolling: Bool { readingMode == .scroll }
    #if os(macOS)
    var readingWindow: NSWindow? { nativeBookReader?.view.window ?? webView.window }
    #else
    var readingWindow: UIWindow? { nativeBookReader?.view.window ?? webView.window }
    #endif
    var positionLabel: String {
        guard let p = position else { return "" }
        return p.mode == .scroll && nativeBookReader == nil ? "\(Int(p.progress * 100))%" : "\(p.page) / \(p.pageCount)"
    }
    private var notesCoverReading: Bool {
        #if os(iOS)
        return (showNoteGraph || selectionDiscussion != nil) && UIDevice.current.userInterfaceIdiom != .pad
        #else
        return showNoteGraph || selectionDiscussion != nil
        #endif
    }
    var snapshot: ReadingSnapshot? {
        guard !loading, !handwritingActive, !notesCoverReading, quickNoteDraft == nil, let book = currentBook, let p = position else { return nil }
        #if os(macOS)
        let readerName = "Mac"
        #else
        let readerName = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        var snapshot = ReadingSnapshot(sessionID: controlSessionID, bookID: book.id, title: book.title,
            page: p.page, pageCount: p.pageCount, locator: p.locator, chapter: p.chapter,
            progress: p.progress, canGoNext: p.canGoNext, canGoPrevious: p.canGoPrevious, readingMode:p.mode,viewportOffset:p.viewportOffset,readerName:readerName)
        snapshot.supportsFractionalScroll = nativeBookReader == nil || (p.mode == .scroll && !isPDFTextLayout)
        snapshot.maxScrollLines = 16
        return snapshot
    }
    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "reader")
        config.setURLSchemeHandler(ReaderPageNoteSchemeHandler(directory:directory),forURLScheme:"bookslide-ink")
        #if os(macOS)
        let view = ReaderAnnotationWebView(frame:.zero,configuration:config)
        view.onAnnotationAction = { [weak self] type, value in self?.receiveAnnotation(type,value:value) }
        #else
        let view = ReaderTextWebView(frame:.zero,configuration:config)
        view.accessibilityIdentifier = "reader-book-web"
        view.onAnnotationAction = { [weak self] type, value in self?.receiveAnnotation(type,value:value) }
        view.onAnnotationMenuVisibilityChange = { [weak self] visible in
            guard let self else { return }
            if self.inlineInkMenuActive != visible { self.inlineInkMenuActive = visible }
            if visible { _ = self.inlineInk?.suspend() }
        }
        #endif
        view.navigationDelegate = self
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = appearance.mode == .scroll
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        view.allowsBackForwardNavigationGestures = false
        return view
    }()
    static var resources: URL {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "Reader", withExtension: nil)!
        #else
        return Bundle.main.url(forResource: "Reader", withExtension: nil)!
        #endif
    }
    override convenience init() {
        self.init(directory:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("BookSlide/Library",isDirectory:true))
    }
    init(directory: URL, loadExternalSources: Bool = true) {
        self.directory = directory
        externalSourcesEnabled = loadExternalSources
        progressStore = loadExternalSources ? ProgressStore() : ProgressStore(directory:directory.appendingPathComponent("TestProgress",isDirectory:true))
        super.init()
        do { try ReaderDiscussionCredentials.configureFromLaunchEnvironment() }
        catch { self.error = "AI 密钥未能保存：\(error.localizedDescription)" }
        cloudSyncConfigured = progressStore.cloudConfigured
        cloudFolderName = progressStore.cloudFolderName
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let saved = try LibraryIndexStore(directory:directory).load([LibraryBook].self) {
                books = saved.value
                if saved.recovered {
                    try LibraryIndexStore(directory:directory).save(books)
                    error = "书库索引已从本机备份恢复。请检查最近的阅读位置。"
                }
            }
            libraryLoaded = true
            if let data = UserDefaults.standard.data(forKey:"readerAppearance"), let saved = try? JSONDecoder().decode(ReaderAppearance.self, from:data) { appearance = saved }
            #if os(macOS)
            if loadExternalSources && !UserDefaults.standard.bool(forKey:"paperReadingDefaultsV2") {
                appearance = ReaderAppearance()
                UserDefaults.standard.set(try? JSONEncoder().encode(appearance),forKey:"readerAppearance")
                UserDefaults.standard.set(true,forKey:"paperReadingDefaultsV2")
            }
            #endif
            acceptedAppearance = appearance
            if books.isEmpty, FileManager.default.fileExists(atPath: Self.resources.appendingPathComponent("QuietHours.epub").path) {
                let id = UUID(), filename = UUID().uuidString + ".epub"
                try FileManager.default.copyItem(at:Self.resources.appendingPathComponent("QuietHours.epub"), to:directory.appendingPathComponent(filename))
                books = [LibraryBook(id:id,title:"留一点时间，给阅读",author:"书籍人生 · 阅读体验",filename:filename)]
                save()
            }
            webView.loadFileURL(Self.resources.appendingPathComponent("index.html"), allowingReadAccessTo: Self.resources)
            #if os(macOS)
            if loadExternalSources { refreshAppleBooks() }
            #endif
            guard loadExternalSources else { return }
            progressTimer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in
                Task { @MainActor in await self?.syncProgress() }
            }
            Task { @MainActor in await self.syncProgress() }
        } catch { self.error = "无法载入书架：\(error.localizedDescription)" }
    }
    func save() {
        guard libraryLoaded else { return }
        do {
            try LibraryIndexStore(directory:directory).save(books)
            #if os(macOS)
            if let path = currentBook?.sourcePath, position != nil { try LibraryCatalog.markRead(URL(fileURLWithPath:path)) }
            #endif
        }
        catch { self.error = "阅读进度未能保存：\(error.localizedDescription)" }
    }
    #if os(macOS)
    private var sharedCovers: [UUID:Data] = [:]
    func sharedCatalog() -> [SharedLibraryBook] {
        visibleBooks.compactMap { book in
            guard let format = book.format else { return nil }
            if sharedCovers[book.id] == nil, let image = cover(book),
               let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:180,pixelsHigh:260,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
                image.draw(in:NSRect(x:0,y:0,width:180,height:260))
                NSGraphicsContext.restoreGraphicsState()
                sharedCovers[book.id] = bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.65])
            }
            return SharedLibraryBook(id:book.id,title:book.title,author:book.author,lastRead:book.lastRead,cover:sharedCovers[book.id],progressKey:book.progressKey,format:format)
        }
    }
    private var appleBooksAccess: URL?
    func chooseAppleBooksFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = LibraryCatalog.appleBooksDirectories.first
        panel.prompt = "连接书库"; panel.message = "选择 Apple Books 的 Documents 书籍目录。只读取原书，阅读进度单独保存。"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            _ = url.startAccessingSecurityScopedResource(); self.appleBooksAccess = url
            if let data = try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) { UserDefaults.standard.set(data,forKey:"appleBooksFolderBookmark") }
            self.refreshAppleBooks()
        }
    }
    func refreshAppleBooks() {
        if appleBooksAccess == nil, let data = UserDefaults.standard.data(forKey:"appleBooksFolderBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData:data,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale) {
                _ = url.startAccessingSecurityScopedResource(); appleBooksAccess = url
            }
        }
        let roots = appleBooksAccess.map { [$0] } ?? LibraryCatalog.appleBooksDirectories
        let hidden = Set(UserDefaults.standard.stringArray(forKey:"hiddenAppleBooks") ?? [])
        Task { @MainActor in
            do {
                let found = try await Task.detached(priority:.userInitiated) { try LibraryCatalog.allBooks(appleDirectories:roots).filter { $0.source == "Apple Books" } }.value
                needsAppleBooksFolder = found.isEmpty
                for item in found where !hidden.contains(item.url.path) {
                    if let index = books.firstIndex(where: { $0.sourcePath == item.url.path }) {
                        books[index].lastRead = max(books[index].lastRead,item.lastRead)
                    } else {
                        var book = LibraryBook(id:UUID(),title:item.title,author:item.author,filename:"")
                        book.sourcePath = item.url.path; book.lastRead = item.lastRead
                        books.append(book)
                    }
                }
                save()
                let pending = books.filter { $0.sourcePath != nil && !FileManager.default.fileExists(atPath:directory.appendingPathComponent($0.id.uuidString + ".cover").path) }.map { ($0.id,$0.sourcePath!) }
                let covers = await Task.detached(priority:.utility) {
                    pending.compactMap { id, path -> (UUID,Data)? in
                        let file = URL(fileURLWithPath:path)
                        let data: Data?
                        switch BookFormat(filename:file.lastPathComponent) {
                        case .epub: data = EPUBArchive.coverData(at:file)
                        case .pdf: data = (try? BookImportFile.read(file)).flatMap { try? PDFBookReader.metadata($0).cover }
                        case nil: data = nil
                        }
                        guard let data else { return nil }
                        return (id,data)
                    }
                }.value
                for (id,data) in covers where ReaderImage(data:data) != nil {
                    try? data.write(to:directory.appendingPathComponent(id.uuidString + ".cover"),options:.atomic)
                }
                coverRevision += 1
            } catch { self.error = "无法刷新 Apple Books：\(error.localizedDescription)" }
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = BookFormat.allCases.map(\.contentType)
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = true
        panel.message = "导入 EPUB 或 PDF，书籍会保存在本机书架。"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importBooks(panel.urls)
        }
    }
    #endif
    func importBooks(_ urls: [URL]) {
        guard libraryLoaded else { error = "书库尚未载入，请先恢复书库后再导入。"; return }
        guard !importingBooks, !urls.isEmpty else { return }
        importingBooks = true; importMessage = nil
        let destination = directory
        let existingFiles = books.filter { $0.contentHash == nil && !$0.filename.isEmpty }.map { ($0.id, destination.appendingPathComponent($0.filename)) }
        Task { @MainActor in
            defer { importingBooks = false }
            // Fingerprint older imports once, without blocking scrolling or touch input.
            let hashes = await Task.detached(priority:.utility) {
                existingFiles.compactMap { id, url -> (UUID, String)? in
                    guard let data = try? BookImportFile.read(url) else { return nil }
                    return (id, BookImportFile.fingerprint(data))
                }
            }.value
            for (id, hash) in hashes {
                if let index = books.firstIndex(where: { $0.id == id }) { books[index].contentHash = hash }
            }
            var imported = 0, reused = 0, failures: [String] = [], singleID: UUID?
            for url in urls {
                var createdFile: URL?
                do {
                    guard let format = BookFormat(filename:url.lastPathComponent) else { throw BookImportFile.Failure.format }
                    let (data, hash, metadata) = try await Task.detached(priority:.userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try BookImportFile.read(url)
                        let metadata = format == .pdf ? try PDFBookReader.metadata(data) : nil
                        return (data, BookImportFile.fingerprint(data), metadata)
                    }.value
                    let existing = books.first { $0.contentHash == hash }
                    if existing == nil || existing?.filename.isEmpty == true ||
                        !FileManager.default.fileExists(atPath:destination.appendingPathComponent(existing?.filename ?? "").path) {
                        let file = destination.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
                        try await Task.detached(priority:.utility) { try data.write(to:file,options:.atomic) }.value
                        createdFile = file
                    }
                    // Re-read after I/O so concurrent note edits are preserved.
                    var updated = books
                    let id: UUID
                    let duplicate: Bool
                    if let index = updated.firstIndex(where: { $0.contentHash == hash }) {
                        // Reimport restores a hidden item, including its bookmarks and position.
                        if let createdFile { updated[index].filename = createdFile.lastPathComponent }
                        updated[index].hidden = false; id = updated[index].id; duplicate = true
                    } else {
                        guard let createdFile else { throw ReaderError.message("导入文件尚未准备好，请重试。") }
                        var book = LibraryBook(id:UUID(),title:metadata?.title ?? url.deletingPathExtension().lastPathComponent,
                                               author:metadata?.author ?? format.label,filename:createdFile.lastPathComponent)
                        book.contentHash = hash
                        if format == .pdf { book.progressKey = hash }
                        updated.insert(book,at:0); id = book.id; duplicate = false
                    }
                    try LibraryIndexStore(directory:directory).save(updated)
                    books = updated; singleID = id
                    if let cover = metadata?.cover { storeCover(cover, bookID:id) }
                    if duplicate { reused += 1 } else { imported += 1 }
                } catch {
                    if let createdFile { try? FileManager.default.removeItem(at:createdFile) }
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                let more = failures.count > 8 ? "\n另有 \(failures.count - 8) 个文件未能导入。" : ""
                importMessage = "已导入 \(imported) 本，已在书库 \(reused) 本，未完成 \(failures.count) 本。\n\n" + failures.prefix(8).joined(separator:"\n") + more
            } else if urls.count > 1 {
                importMessage = "已导入 \(imported) 本" + (reused > 0 ? "，另有 \(reused) 本已在书库，无需重复导入。" : "。")
            }
            if urls.count == 1, failures.isEmpty, let id = singleID { open(id) }
        }
    }
    func open(_ id: UUID) {
        guard !busy, !loading, books.contains(where:{$0.id == id}) else { return }
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return }
        inlineInkStatus = nil
        inlineInkSelectionActive = false
        (webView as? ReaderTextWebView)?.dismissAnnotationMenu()
        #endif
        nativeSearchTask?.cancel()
        nativeBookReader = nil
        nativeSelection = nil
        pdfTextTarget = nil
        acceptedAppearance = appearance
        controlSessionID = UUID()
        restoringProgress = false
        save(); pendingProgress = nil; appliedProgressID = nil; dismissedProgressID = nil; lastRecordedLocator = nil; currentID = id; sessionID = UUID(); position = nil; chapters = []; results = []; searchState = .idle; searchGeneration = UUID(); error = nil
        selectionEntity = nil; readingControlsVisible = false; locationsReady = false; readingNotice = nil; annotationDraft = nil; quickNoteDraft = nil; annotationSessionID = UUID()
        noteUndoID = nil; visiblePageNoteIDs = []; hiddenPageNoteIDs = []; pageNoteToView = nil
        loadNoteDrafts(bookID:id)
        loading = true; pendingBook = id
        loadPending()
    }
    private func loadPending() {
        guard let id = pendingBook, let book = books.first(where:{$0.id == id}) else { return }
        guard book.format != .epub || engineReady else { return }
        pendingBook = nil
        let openingSession = sessionID
        openTask = Task { @MainActor in
            do {
                guard let format = book.format else { throw BookImportFile.Failure.format }
                let file = book.sourcePath.map { URL(fileURLWithPath:$0) } ?? directory.appendingPathComponent(book.filename)
                let data = try await Task.detached(priority:.userInitiated) { try Self.bookData(at:file, format:format) }.value
                guard !Task.isCancelled, sessionID == openingSession, currentID == id else { return }
                switch format {
                case .pdf:
                    let hash: String
                    if let contentHash = book.contentHash { hash = contentHash }
                    else { hash = await Task.detached(priority:.utility) { BookImportFile.fingerprint(data) }.value }
                    let cache = pdfTextCache(bookID:id,hash:hash)
                    let enhanced = await Task.detached(priority:.utility) {
                        try? Data(contentsOf:cache,options:.mappedIfSafe)
                    }.value
                    guard !Task.isCancelled, sessionID == openingSession, currentID == id else { return }
                    let reader: PDFBookReader
                    if let enhanced, let recognized = try? PDFBookReader(data:enhanced) { reader = recognized }
                    else { reader = try PDFBookReader(data:data) }
                    if let index = books.firstIndex(where:{ $0.id == id }) {
                        books[index].progressKey = hash
                    }
                    reader.onPositionChange = { [weak self] position in
                        guard let self, self.sessionID == openingSession else { return }
                        self.acceptEnginePosition(position)
                    }
                    reader.onSelectionChange = { [weak self] selection in
                        guard let self, self.sessionID == openingSession, !self.isPDFTextLayout else { return }
                        self.nativeSelection = selection
                        #if os(iOS)
                        self.inlineInkSelectionActive = selection != nil
                        #endif
                    }
                    #if os(iOS)
                    reader.selectionMenu = { [weak self] selection in
                        guard let self, self.sessionID == openingSession, !self.isPDFTextLayout else { return [] }
                        return self.nativeSelectionMenu(for:selection)
                    }
                    #endif
                    reader.onToggleControls = { [weak self] in self?.readingControlsVisible.toggle() }
                    chapters = reader.chapters
                    _ = reader.applyAppearance(appearance)
                    acceptEnginePosition(reader.open(at:book.locator))
                    nativeBookReader = reader
                    refreshAnnotations()
                    refreshPageNotes()
                    locationsReady = true
                case .epub:
                    let fontURL = Self.resources.appendingPathComponent("ReadingSerif.woff2")
                    let font = fontSent ? "" : await Task.detached(priority:.userInitiated) { (try? Data(contentsOf:fontURL).base64EncodedString()) ?? "" }.value
                    guard !Task.isCancelled, sessionID == openingSession, currentID == id else { return }
                    let value = try await webView.callAsyncJavaScript("return await reader.open(data, locator, settings, font, viewport)", arguments:["data":data.base64EncodedString(),"locator":book.locator,"settings":try engineSettings(),"font":font,"viewport":try book.readingViewport.map { try dictionary($0) } as Any? ?? NSNull()], in:nil, contentWorld:.page)
                    fontSent = true
                    guard currentID == id, sessionID == openingSession else { return }
                    if let value { acceptPosition(value) }
                }
                await syncProgress()
                guard currentID == id, sessionID == openingSession else { return }
                if let key = currentBook?.progressKey {
                    if let record = try progressStore.latest(bookKey:key) {
                        do {
                            if record.deviceID == progressDeviceID, !book.locator.isEmpty { appliedProgressID = record.id }
                            else { try await restoreProgress(record) }
                        }
                        catch { progressStatus = "同步位置未能恢复 · 保留本机阅读位置" }
                    } else if !book.locator.isEmpty, let p = position, let anchor = p.anchor {
                        let legacy = ReadingProgress(bookKey:key,deviceID:progressDeviceID,deviceName:progressDeviceName,updatedAt:book.lastRead,anchor:anchor,cfi:p.locator,progress:p.progress)
                        try progressStore.merge([legacy]); appliedProgressID = legacy.id
                    }
                }
                loading = false
                onReadingChanged?()
            } catch { guard currentID == id, sessionID == openingSession, !Task.isCancelled else { return }; loading = false; readingControlsVisible = true; self.error = "无法打开书籍：\((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)" }
        }
    }
    func setPDFTextLayout(_ enabled: Bool) {
        guard pdfBookReader != nil, !loading, !busy,
              let index = books.firstIndex(where:{ $0.id == currentID }) else { return }
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return }
        #endif
        clearNativeSelection()
        books[index].prefersTextLayout = enabled
        save()
    }

    func clearNativeSelection() {
        nativeBookReader?.clearSelection()
        nativeSelection = nil
        nativeSelectionGeneration = UUID()
        #if os(iOS)
        inlineInkSelectionActive = false
        #endif
    }

    private func pdfTextCache(bookID: UUID, hash: String) -> URL {
        let key = hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : "unavailable"
        return directory.appendingPathComponent("PDFText",isDirectory:true).appendingPathComponent(bookID.uuidString + "-" + key + ".pdf")
    }

    func recognizePDFText() {
        guard !pdfTextRecognitionRunning, let book = currentBook, book.format == .pdf, let hash = book.progressKey else { return }
        let file = book.sourcePath.map { URL(fileURLWithPath:$0) } ?? directory.appendingPathComponent(book.filename)
        let cache = pdfTextCache(bookID:book.id,hash:hash)
        let session = sessionID
        pdfTextRecognitionRunning = true
        Task { @MainActor in
            defer { pdfTextRecognitionRunning = false }
            do {
                try await Task.detached(priority:.userInitiated) {
                    let original = try BookImportFile.read(file)
                    guard BookImportFile.fingerprint(original) == hash else {
                        throw ReaderError.message("PDF 已更新，请重新打开后再识别")
                    }
                    let data = try PDFScanText.recognize(in:original)
                    try FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try data.write(to:cache,options:.atomic)
                }.value
                guard sessionID == session else { return }
                showReadingNotice("已识别扫描文字")
                open(book.id)
            } catch {
                if sessionID == session { self.error = error.localizedDescription }
            }
        }
    }

    nonisolated static func bookData(at file: URL, format: BookFormat) throws -> Data {
        #if os(macOS)
        if format == .epub { return try EPUBArchive.data(at:file) }
        #endif
        return try BookImportFile.read(file)
    }

    func close() {
        #if os(iOS)
        guard suspendInlineInkForNavigation() else {
            error = inlineInk?.isDrawing == true ? "请先抬起笔，再返回书库。" : (inlineInkStatus ?? "笔迹尚未保存，请重试后返回书库。")
            return
        }
        inlineInkSelectionActive = false
        (webView as? ReaderTextWebView)?.dismissAnnotationMenu()
        #endif
        finishClosingBook()
    }
    private func finishClosingBook() {
        knowledgeOpenTask?.cancel(); knowledgeOpenTask = nil; pendingGraphNote = nil
        readingSelectionTask?.cancel(); readingSelectionTask = nil
        restoringProgress = false
        handwritingActive = false
        #if os(iOS)
        webView.scrollView.isScrollEnabled = isScrolling
        #endif
        openTask?.cancel(); openTask = nil; pendingBook = nil
        nativeSearchTask?.cancel(); nativeBookReader = nil; nativeSelection = nil
        appearanceWork?.cancel(); appearancePending = false; saveWork?.cancel()
        save(); selectionEntity = nil; pageTurnVisual = nil; pendingProgress = nil; loading = false; busy = false; locationsReady = false; annotationDraft = nil; quickNoteDraft = nil
        showNoteGraph = false; knowledgeCanvasExpanded = false; selectionDiscussion = nil; graphNoteID = nil; discussionNoteID = nil; discussionFocusMessage = nil
        showProgressSettings = false
        webView.evaluateJavaScript("reader.cancel()",completionHandler:nil)
        currentID = nil; position = nil; sessionID = UUID(); controlSessionID = UUID(); results = []; searchState = .idle; searchGeneration = UUID(); onReadingChanged?()
        noteUndoID = nil; visiblePageNoteIDs = []; hiddenPageNoteIDs = []; pageNoteToView = nil
        textNoteDrafts = []; inkNoteDrafts = []
    }
    func invalidateSession() { controlSessionID = UUID(); onReadingChanged?() }
    /// Normal page boundaries and overlapping input never interrupt local reading.
    @MainActor func turnLocally(_ direction: PageDirection) async {
        guard !busy, !loading, let position,
              direction == .next ? position.canGoNext : position.canGoPrevious else { return }
        let readingSession = sessionID
        if let message = await turn(direction) {
            guard sessionID == readingSession, let current = self.position,
                  direction == .next ? current.canGoNext : current.canGoPrevious else { return }
            showReadingNotice(message.replacingOccurrences(of:"Error: ",with:""))
        }
    }
    func showReadingNotice(_ message: String) {
        noticeWork?.cancel(); readingNotice = message
        let work = DispatchWorkItem { [weak self] in self?.readingNotice = nil }
        noticeWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+3,execute:work)
    }
    #if os(iOS)
    /// User initiated navigation must explain why it cannot leave editable ink.
    @discardableResult func suspendInlineInkForNavigation() -> Bool {
        guard inlineInk?.suspend() != false else {
            showReadingNotice(inlineInk?.isDrawing == true ? "请先抬起笔，再进行此操作。" : (inlineInkStatus ?? "笔迹尚未保存，请重试。"))
            return false
        }
        return true
    }
    #endif
    @MainActor func turn(_ direction: PageDirection, scrollLines: Double? = nil) async -> String? {
        guard !handwritingActive else { return "正在书写，请先完成批注" }
        guard !busy, !loading, snapshot != nil else { return "正在排版，请稍候" }
        #if os(iOS)
        guard inlineInk?.suspend() != false else { return "笔迹尚未保存，请重试" }
        #endif
        guard scrollLines != nil || (direction == .next ? position?.canGoNext == true : position?.canGoPrevious == true) else { return direction == .next ? "已到末页" : "已到首页" }
        if let nativeBookReader {
            let target: EnginePosition?
            if let scrollLines, !isPDFTextLayout { target = nativeBookReader.scroll(direction,lines:scrollLines) }
            else { target = nativeBookReader.turn(direction) }
            guard let target else { return direction == .next ? "已到末页" : "已到首页" }
            clearNativeSelection()
            pdfTextTarget = nil
            acceptEnginePosition(target)
            return nil
        }
        let turnSession = sessionID
        busy = true; defer { if sessionID == turnSession { busy = false; pageTurnVisual = nil } }
        #if os(macOS)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        #endif
        if !isScrolling, !reduceMotion, let image = try? await webView.takeSnapshot(configuration:nil) {
            guard sessionID == turnSession else { return "阅读已结束" }
            pageTurnVisual = ReaderPageTurn(image:image,direction:direction)
            // Present the captured sheet before changing the underlying WebKit page.
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        guard sessionID == turnSession else { return "阅读已结束" }
        let previous = position?.locator, previousOffset = position?.viewportOffset
        do {
            let value = try await webView.callAsyncJavaScript("return await reader.turn(direction,lines,true)",arguments:["direction":direction.rawValue,"lines":scrollLines as Any? ?? NSNull()],in:nil,contentWorld:.page)
            guard sessionID == turnSession else { return "阅读已结束" }
            if let value { acceptPosition(value) }
            #if os(iOS)
            if !UIAccessibility.isVoiceOverRunning { readingControlsVisible = false }
            #endif
            let movedViewport = previousOffset.flatMap { before in position?.viewportOffset.map { abs($0-before) > 0.5 } } ?? false
            guard scrollLines != nil || previous != position?.locator || movedViewport else { return "页面尚未变化，请查看阅读器" }
            if pageTurnVisual != nil {
                withAnimation(.easeInOut(duration:0.28)) { pageTurnVisual?.angle = direction == .next ? -90 : 90 }
                try? await Task.sleep(nanoseconds:300_000_000)
                guard sessionID == turnSession else { return "阅读已结束" }
            }
            return nil
        } catch { return (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription }
    }
    @discardableResult func go(_ href: String, viewport: ReaderViewport? = nil) -> Bool {
        guard !busy, !loading else { return false }
        guard !handwritingActive else { showReadingNotice("请先结束书写，再跳转阅读位置。"); return false }
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return false }
        #endif
        if let nativeBookReader {
            guard let position = nativeBookReader.go(to:href,userDriven:true) else { return false }
            clearNativeSelection()
            pdfTextTarget = PDFTextLocator.decode(href)?.first?.range
            acceptEnginePosition(position)
            return true
        }
        let navigationSession = sessionID
        busy = true
        Task { @MainActor in
            guard sessionID == navigationSession else { return }
            defer { if sessionID == navigationSession { busy = false } }
            do {
                let value = try await webView.callAsyncJavaScript("return await reader.go(href,viewport)",arguments:["href":href,"viewport":try viewport.map { try dictionary($0) } as Any? ?? NSNull()],in:nil,contentWorld:.page)
                guard sessionID == navigationSession else { return }
                if let value { acceptPosition(value) }
            } catch { if sessionID == navigationSession { self.error = error.localizedDescription } }
        }
        return true
    }
    private func engineSettings() throws -> [String:Any] {
        var settings = try dictionary(appearance)
        settings["annotations"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(pageAnnotations))
        settings["pageNotes"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(currentBook?.pageNotes ?? []))
        settings["annotationSession"] = annotationSessionID.uuidString
        settings["annotationColor"] = UserDefaults.standard.string(forKey:"readerAnnotationColor") ?? "yellow"
        settings["nativeAnnotationMenu"] = true
        #if os(iOS)
        settings["nativeTouchControls"] = true
        if UIDevice.current.userInterfaceIdiom == .pad {
            // A landscape iPad has room for a fuller page, capped at a
            // comfortable line length. Keep the selected margin inside that
            // measure; zero margins remain explicitly edge-to-edge.
            settings["scrollMaxTextWidth"] = appearance.margin > 0 ? min(1040,max(960,appearance.fontSize*48)) : 0
            settings["paragraphSpacing"] = 0.65
            settings["headingSpacing"] = 0.75
        }
        #endif
        return settings
    }
    @discardableResult func seek(_ progress: Double) -> Bool {
        guard progress.isFinite, (0...1).contains(progress), locationsReady, !busy, !loading else { return false }
        guard !handwritingActive else { showReadingNotice("请先结束书写，再调整阅读进度。"); return false }
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return false }
        #endif
        if let nativeBookReader {
            guard let position = nativeBookReader.seek(progress) else { return false }
            clearNativeSelection()
            pdfTextTarget = nil
            acceptEnginePosition(position)
            return true
        }
        let seekingSession = sessionID
        busy = true
        Task { @MainActor in
            guard sessionID == seekingSession else { return }
            defer { if sessionID == seekingSession { busy = false } }
            do {
                let value = try await webView.callAsyncJavaScript("return await reader.progress(value)",arguments:["value":progress],in:nil,contentWorld:.page)
                guard sessionID == seekingSession else { return }
                if let value { acceptPosition(value) }
            } catch { if sessionID == seekingSession { showReadingNotice("未能定位，请重试") } }
        }
        return true
    }
    func updateAppearance() {
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { appearance = acceptedAppearance; return }
        webView.scrollView.isScrollEnabled = isScrolling
        #endif
        acceptedAppearance = appearance
        UserDefaults.standard.set(try? JSONEncoder().encode(appearance),forKey:"readerAppearance")
        appearanceWork?.cancel()
        if let nativeBookReader {
            appearancePending = false
            if !loading { acceptEnginePosition(nativeBookReader.applyAppearance(appearance)) }
            return
        }
        guard currentID != nil, supportsReflow else { appearancePending = false; return }
        appearancePending = true
        let requestedSession = sessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentID != nil, self.sessionID == requestedSession else { return }
            Task { @MainActor in
                guard self.currentID != nil, self.sessionID == requestedSession else { return }
                guard !self.navigationBusy, !self.loading else { self.updateAppearance(); return }
                guard !self.handwritingActive else { self.appearancePending = false; return }
                let appearanceSession = self.sessionID
                self.busy = true; self.appearancePending = false
                defer { if self.sessionID == appearanceSession { self.busy = false } }
                do {
                    let result = try await self.webView.callAsyncJavaScript("return await reader.appearance(settings)",arguments:["settings":try self.engineSettings()],in:nil,contentWorld:.page)
                    guard self.sessionID == appearanceSession else { return }
                    if let result { self.acceptPosition(result) }
                } catch { if self.sessionID == appearanceSession { self.error = "排版调整未完成：\(error.localizedDescription)" } }
            }
        }
        appearanceWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    func search(_ query: String) {
        nativeSearchTask?.cancel()
        let query = ReaderSearchState.normalized(query)
        let generation = UUID(); searchGeneration = generation
        results = []
        guard !query.isEmpty, currentID != nil else { searchState = .idle; return }
        searchState = .searching
        if let nativeBookReader {
            nativeSearchTask = Task { @MainActor in
                do {
                    let matches = try await nativeBookReader.search(query)
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    results = matches
                    searchState = .complete(matches.count)
                } catch {
                    if !Task.isCancelled, searchGeneration == generation { searchState = .failed }
                }
            }
            return
        }
        Task { @MainActor in
            do {
                let value = try await webView.callAsyncJavaScript("return await reader.search(query)",arguments:["query":query],in:nil,contentWorld:.page)
                guard searchGeneration == generation else { return }
                if let value { results = try JSONDecoder().decode([ChapterItem].self,from:JSONSerialization.data(withJSONObject:value)) }
                searchState = .complete(results.count)
            } catch { if searchGeneration == generation { searchState = .failed } }
        }
    }
    var isBookmarked: Bool { currentBook?.bookmarks.contains(where:{$0.id == position?.locator}) == true }
    @discardableResult func toggleBookmark() -> Bool {
        guard !loading, !busy, let p = position else { return false }
        let adding = !isBookmarked
        guard setReaderBookmark(ReaderBookmark(id:p.locator,title:p.chapter,progress:p.progress,viewport:p.viewport),present:adding) else { return false }
        showReadingNotice(adding ? "已添加书签" : "已移除书签")
        return true
    }
    @discardableResult func setReaderBookmark(_ bookmark: ReaderBookmark,present: Bool) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == currentID }), !bookmark.id.isEmpty else { return false }
        var updated = books
        updated[index].bookmarks.removeAll { $0.id == bookmark.id }
        if present { updated[index].bookmarks.append(bookmark) }
        do {
            try LibraryIndexStore(directory:directory).save(updated); books = updated; return true
        } catch { self.error = "书签未能保存，请重试。"; return false }
    }
    private func storeCover(_ data: Data, bookID: UUID) {
        try? data.write(to:directory.appendingPathComponent(bookID.uuidString + ".cover"),options:.atomic)
        coverRevision += 1
    }

    func cover(_ book: LibraryBook) -> ReaderImage? {
        guard let data = try? Data(contentsOf:directory.appendingPathComponent(book.id.uuidString + ".cover")) else { return nil }; return ReaderImage(data:data)
    }
    func remove(_ book: LibraryBook) {
        guard book.id != currentID, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        var updated = books
        updated[index].hidden = true
        do { try LibraryIndexStore(directory:directory).save(updated); books = updated }
        catch { self.error = "隐藏图书未能保存，请重试。" }
    }
    func restoreHiddenBooks() {
        guard allowsLibraryWrites else { return }
        var updated = books
        for index in updated.indices { updated[index].hidden = false }
        do { try LibraryIndexStore(directory:directory).save(updated); books = updated }
        catch { self.error = "恢复图书未能保存，请重试。"; return }
        UserDefaults.standard.removeObject(forKey:"hiddenAppleBooks")
        UserDefaults.standard.removeObject(forKey:"hiddenRemoteBooks")
        #if os(macOS)
        refreshAppleBooks()
        #else
        Task { await syncMacLibrary() }
        #endif
    }
    func dictionary<T: Encodable>(_ value: T) throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
    }
    @discardableResult func acceptPosition(_ value: Any) -> Bool {
        guard currentID != nil, let object = value as? [String:Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject:object),
              let p = try? JSONDecoder().decode(EnginePosition.self,from:data), p.page > 0, p.pageCount > 0, p.progress.isFinite,
              p.session == nil || p.session == annotationSessionID.uuidString else { return false }
        acceptEnginePosition(p)
        return true
    }

    func acceptEnginePosition(_ p: EnginePosition) {
        #if os(iOS)
        if p.userDriven == true, let previous = position,
           previous.locator != p.locator || previous.viewportOffset != p.viewportOffset,
           !UIAccessibility.isVoiceOverRunning { readingControlsVisible = false }
        #endif
        position = p
        onReadingChanged?()
        if let index = books.firstIndex(where:{$0.id == currentID}) {
            books[index].furthestReadProgress = max(books[index].furthestReadProgress ?? books[index].progress,p.progress)
            books[index].readingViewport = p.viewport
            books[index].locator = p.locator; books[index].progress = p.progress; books[index].lastRead = Date()
        }
        if !loading, !restoringProgress, p.userDriven == true { recordProgress(p) }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
            if self?.position?.userDriven == true { Task { @MainActor in await self?.syncProgress() } }
        }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.4,execute:work)
    }
    private func diagnose(_ text: String) {
        #if DEBUG
        let url = URL(fileURLWithPath:"/tmp/bookslide-reader.log")
        let data = Data((text + "\n").utf8)
        if let file = try? FileHandle(forWritingTo:url) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf:data) }
        else { try? data.write(to:url) }
        #endif
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String:Any], let type = body["type"] as? String else { return }
        guard type == "ready" || supportsReflow else { return }
        diagnose("JS event: \(type) \(type == "diagnostic" ? String(describing:body["value"]) : "")")
        switch type {
        case "ready": engineReady = true; loadPending()
        case "controls": readingControlsVisible.toggle()
        case "locationsReady": locationsReady = true
        case "position": if let value = body["value"] { acceptPosition(value) }
        case "annotationChange", "annotationEdit", "annotationDiscuss", "annotationTranslate", "annotationEntity", "annotationPerson", "annotationRemove", "annotationPencilHighlight":
            receiveAnnotation(type, value:body["value"])
        case "pageNoteVisibility":
            guard let value = body["value"] as? [String:Any], value["session"] as? String == annotationSessionID.uuidString,
                  let visible = value["visible"] as? [String], let hidden = value["hidden"] as? [String], currentID != nil else { return }
            let ids = Set(currentPageNotes.map(\.id))
            visiblePageNoteIDs = visible.compactMap(UUID.init(uuidString:)).filter { ids.contains($0) }
            hiddenPageNoteIDs = hidden.compactMap(UUID.init(uuidString:)).filter { ids.contains($0) }
        case "annotationSelection":
            let value = body["value"] as? [String:Any]
            #if os(macOS)
            (webView as? ReaderAnnotationWebView)?.annotationContext = value?["session"] as? String == annotationSessionID.uuidString ? value : nil
            #else
            let active = value?["session"] as? String == annotationSessionID.uuidString
            if inlineInkSelectionActive != active {
                inlineInkSelectionActive = active
                if active { _ = inlineInk?.suspend() }
            }
            #endif
        case "annotationMenu":
            guard let value = body["value"] as? [String:Any], value["session"] as? String == annotationSessionID.uuidString,
                  let x = value["x"] as? Double, let y = value["y"] as? Double else { return }
            #if os(macOS)
            (webView as? ReaderAnnotationWebView)?.presentAnnotationMenu(context:value,x:x,y:y)
            #else
            (webView as? ReaderTextWebView)?.presentAnnotationMenu(context:value,x:x,y:y)
            #endif
        case "outline":
            guard let value = body["value"] as? [String:Any], value["session"] as? String == annotationSessionID.uuidString,
                  let toc = value["toc"], let data = try? JSONSerialization.data(withJSONObject:toc),
                  let items = try? JSONDecoder().decode([ChapterItem].self,from:data) else { return }
            chapters = items
        case "metadata":
            guard let metadata = body["value"] as? [String:Any], let index = books.firstIndex(where:{$0.id == currentID}) else { return }
            if let package = metadata["packageData"] as? String, let data = Data(base64Encoded:package) {
                books[index].progressKey = ReadingProgress.bookKey(package:data)
            }
            if let title = metadata["title"] as? String, !title.isEmpty { books[index].title = title }
            if let author = metadata["author"] as? String, !author.isEmpty { books[index].author = author }
            if let toc = metadata["toc"], let data = try? JSONSerialization.data(withJSONObject:toc) { chapters = (try? JSONDecoder().decode([ChapterItem].self,from:data)) ?? [] }
            save()
        case "cover":
            if let id = currentID, let base64 = body["value"] as? String, let data = Data(base64Encoded:base64), data.count <= 4 * 1024 * 1024, ReaderImage(data:data) != nil {
                storeCover(data,bookID:id)
            }
        case "turn": if let raw = body["value"] as? String, let direction = PageDirection(rawValue:raw) { Task { @MainActor in await turnLocally(direction) } }
        case "error": error = body["value"] as? String
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        diagnose("navigation: \(String(describing:navigationAction.request.url)) main=\(String(describing:navigationAction.targetFrame?.isMainFrame))")
        // Never navigate this privileged host to book links or remote pages.
        if navigationAction.targetFrame?.isMainFrame == true {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true && url?.standardizedFileURL == Self.resources.appendingPathComponent("index.html").standardizedFileURL ? .allow : .cancel)
        } else { decisionHandler(navigationAction.request.url?.scheme == "blob" || ["about:blank", "about:srcdoc"].contains(navigationAction.request.url?.absoluteString ?? "") ? .allow : .cancel) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        engineReady = false; fontSent = false
        if currentBook?.format == .pdf {
            webView.loadFileURL(Self.resources.appendingPathComponent("index.html"),allowingReadAccessTo:Self.resources)
            return
        }
        openTask?.cancel(); openTask = nil; pendingBook = nil
        appearanceWork?.cancel(); appearancePending = false; saveWork?.cancel()
        sessionID = UUID(); controlSessionID = UUID()
        position = nil; loading = false; busy = false
        #if os(iOS)
        let inkRecoverable = inlineInk?.keepDraft() ?? true
        inlineInk?.stop()
        guard inkRecoverable else {
            retainEditorAfterWebContentFailure(webView,message:"阅读进程已重启，笔迹暂未保存。请保留当前页面，重试保存后再返回书库。")
            return
        }
        if let flush = mindMapInputFlush {
            let failedSession = sessionID
            busy = true
            Task { @MainActor in
                let saved = await flush.perform()
                guard sessionID == failedSession else { return }
                guard saved else {
                    retainEditorAfterWebContentFailure(webView,message:"阅读进程已重启，导图修改暂未保存。请先重试保存，再返回书库重新打开。")
                    return
                }
                finishWebContentRecovery(webView)
            }
            return
        }
        #endif
        finishWebContentRecovery(webView)
    }
    private func retainEditorAfterWebContentFailure(_ webView: WKWebView,message: String) {
        position = nil; loading = false; busy = false; readingControlsVisible = true
        error = message
        webView.loadFileURL(Self.resources.appendingPathComponent("index.html"),allowingReadAccessTo:Self.resources)
    }
    private func finishWebContentRecovery(_ webView: WKWebView) {
        finishClosingBook()
        error = "阅读进程已重启，请重新打开这本书"
        webView.loadFileURL(Self.resources.appendingPathComponent("index.html"),allowingReadAccessTo:Self.resources)
    }
}
enum ReaderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
#if os(macOS)
struct EPUBWebView: NSViewRepresentable {
    let reader: ReaderModel
    func makeCoordinator() -> ReaderAnnotationInput { ReaderAnnotationInput(reader:reader) }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.attach(to:reader.webView)
        return reader.webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ReaderAnnotationInput) { coordinator.detach() }
}

#else
struct EPUBWebView: UIViewRepresentable {
    let reader: ReaderModel
    func makeCoordinator() -> ReaderTouchInput { ReaderTouchInput(reader:reader) }
    func makeUIView(context: Context) -> ReaderPencilHost {
        context.coordinator.attach(to:reader.webView)
        return ReaderPencilHost(reader:reader)
    }
    func updateUIView(_ view: ReaderPencilHost, context: Context) { view.ink.updateTools() }
    static func dismantleUIView(_ view: ReaderPencilHost, coordinator: ReaderTouchInput) { view.ink.stop(); coordinator.detach() }
}
#endif

struct BookCanvas: View {
    @ObservedObject var reader: ReaderModel
    var body: some View {
        ZStack {
            if let native = reader.nativeBookReader {
                NativeBookCanvas(view:native.view,reader:reader).id(reader.sessionID)
                    .opacity(reader.isPDFTextLayout ? 0 : 1)
                    .allowsHitTesting(!reader.isPDFTextLayout)
                    .accessibilityHidden(reader.isPDFTextLayout)
                if reader.isPDFTextLayout, let pdf = reader.pdfBookReader {
                    PDFReflowCanvas(reader:reader,pdf:pdf)
                }
            } else if reader.currentID == nil || reader.supportsReflow {
                EPUBWebView(reader:reader)
            }
            if let turn = reader.pageTurnVisual { PageTurnSheet(turn:turn) }
        }.clipped()
            #if os(macOS)
            .overlay(alignment:.top) {
                if let selection = reader.nativeSelection, let id = reader.currentID {
                    ReaderNativeSelectionTools(reader:reader,selection:selection,bookID:id)
                }
            }
            .overlay(alignment:.top) { if !reader.loading { ReaderNoteNotices(reader:reader) } }
            #endif
            .sheet(item:$reader.quickNoteDraft,onDismiss:reader.finishQuickNotePresentation) { ReaderNoteEditor(reader:reader,draft:$0).preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light) }
            .sheet(item:$reader.pageNoteToView) { note in ReaderPageNoteDetail(reader:reader,note:note) }
    }
}
