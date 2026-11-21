import SwiftUI
import UniformTypeIdentifiers

struct PhoneLibraryView: View {
    @StateObject private var reader: ReaderModel
    @StateObject private var ipadReceiver: IPadReaderReceiver
    @State private var ipadRemote = false
    @State private var librarySettings = false
    @ObservedObject private var libraryConnection = MacLibraryConnection.shared
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    init() {
        #if DEBUG
        // UI tests get an isolated, persistent library inside the app sandbox.
        // Relaunching the app still exercises the normal on-disk recovery path.
        let testLibrary = ProcessInfo.processInfo.environment["BOOKSLIDE_UI_TEST_LIBRARY"].flatMap(UUID.init(uuidString:))
        let reader = testLibrary.map {
            ReaderModel(directory:FileManager.default.temporaryDirectory.appendingPathComponent("UITest-\($0.uuidString)"),loadExternalSources:false)
        } ?? ReaderModel()
        if testLibrary != nil {
            reader.appearance = ReaderAppearance()
            if ProcessInfo.processInfo.environment["BOOKSLIDE_UI_TEST_DISCUSSION"] == "1", let book = reader.sampleBook {
                reader.currentID = book.id
                var note = ReaderAnnotation(cfi:"",quote:"",chapter:"全书",progress:0)
                note.discussionScope = ReaderDiscussion.bookScope
                note.title = ReaderDiscussion.defaultTitle
                var discussion = ReaderDiscussion()
                discussion.messages = [.init(role:.assistant,text:"Reading starts with a question.")]
                note.discussion = discussion
                reader.autosaveDiscussion(note,bookID:book.id)
                reader.currentID = nil
            }
            if ProcessInfo.processInfo.environment["BOOKSLIDE_UI_TEST_ENTITY"] == "1", let book = reader.sampleBook {
                reader.currentID = book.id
                if let person = reader.saveKnowledgeEntity(.init(name:"林川",kind:.person)),
                   let place = reader.saveKnowledgeEntity(.init(name:"旧书店",kind:.place)) {
                    _ = reader.connectReadingNodes(from:.init(.entity,person.uuidString),to:.init(.entity,place.uuidString),label:"初次相遇",bookID:book.id)
                }
                reader.currentID = nil
            }
            if let encoded = ProcessInfo.processInfo.environment["BOOKSLIDE_UI_TEST_PDF"],
               let data = Data(base64Encoded:encoded), let index = reader.books.firstIndex(where:{ $0.id == reader.sampleBook?.id }),
               (try? data.write(to:reader.directory.appendingPathComponent("SelectionFixture.pdf"))) != nil {
                reader.books[index].filename = "SelectionFixture.pdf"
                reader.books[index].prefersTextLayout = ProcessInfo.processInfo.environment["BOOKSLIDE_UI_TEST_PDF_LAYOUT"] == "reflow"
            }
        }
        #else
        let reader = ReaderModel()
        #endif
        _reader = StateObject(wrappedValue: reader)
        _ipadReceiver = StateObject(wrappedValue: IPadReaderReceiver(reader: reader))
    }
    @State private var importing = false
    @State private var remote = false
    @State private var query = ""
    @State private var downloadedOnly = false
    @State private var sortByTitle = false
    @State private var downloadTask: Task<Void,Never>?
    @Environment(\.scenePhase) private var scenePhase
    private var books: [LibraryBook] {
        reader.visibleBooks.filter { (!downloadedOnly || reader.isDownloaded($0)) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query)) }
            .sorted { sortByTitle ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.lastRead > $1.lastRead }
    }
    var body: some View {
        Group {
            if reader.currentID != nil {
                PhoneReadingView(reader:reader,ipadReceiver:ipadReceiver)
            } else if isPad {
                IPadLibraryView(reader:reader,importBooks:{ importing = true },
                    showRemote:{ ipadRemote = true },showMacLibrary:{ librarySettings = true },
                    open:open,cancelDownload:cancelDownload)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment:.leading,spacing:26) {
                        if reader.syncingLibrary {
                            ProgressView("正在刷新书库…").font(.caption)
                        } else if let message = reader.libraryMessage {
                            HStack(spacing:12) {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("刷新") { Task { await reader.syncMacLibrary() } }
                            }
                        }
                        if query.isEmpty, !downloadedOnly, !reader.visibleBooks.contains(where: { !$0.locator.isEmpty }), let sample = reader.sampleBook {
                            VStack(alignment:.leading,spacing:10) {
                                Text("从一小段阅读开始").font(.headline)
                                Text("先读示例，也可以导入 EPUB 或 PDF。").font(.subheadline).foregroundStyle(.secondary)
                                Button("试读示例") { open(sample) }.buttonStyle(.borderedProminent).accessibilityIdentifier("library-open-featured")
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
                                .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18))
                        }
                        if query.isEmpty, !downloadedOnly, let recent = books.first(where: { !$0.locator.isEmpty && $0.progress < 1 }) {
                            VStack(alignment:.leading,spacing:14) {
                                Text("继续阅读").font(.title2.weight(.bold))
                                Button { open(recent) } label: {
                                    HStack(spacing:20) {
                                        BookJacket(reader:reader,book:recent).frame(width:76)
                                        VStack(alignment:.leading,spacing:9) {
                                            Text(recent.title).font(.headline).lineLimit(2)
                                            Text(recent.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            ProgressView(value:recent.progress).tint(readingAccent).padding(.top,4)
                                            Text("已读 \(Int(recent.progress*100))%").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }.padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18))
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack(alignment:.firstTextBaseline) {
                            Text(downloadedOnly ? "已下载" : "全部图书").font(.title2.weight(.bold))
                            Spacer()
                            Text("\(books.count) 本").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:136,maximum:210),spacing:24)],alignment:.leading,spacing:28) {
                            ForEach(books) { book in
                                Button { open(book) } label: {
                                    VStack(alignment:.leading,spacing:10) {
                                        BookJacket(reader:reader,book:book)
                                            .overlay(alignment:.bottomTrailing) {
                                                if reader.downloadingBook == book.id {
                                                    ZStack { Circle().stroke(.secondary.opacity(0.25),lineWidth:2); Circle().trim(from:0,to:reader.downloadProgress).stroke(readingAccent,style:StrokeStyle(lineWidth:2,lineCap:.round)).rotationEffect(.degrees(-90)) }
                                                        .frame(width:22,height:22).padding(9).background(.regularMaterial,in:Circle()).padding(8)
                                                }
                                                else if !reader.isDownloaded(book) { Image(systemName:"arrow.down.circle").font(.caption).padding(8).background(.regularMaterial,in:Circle()).padding(8) }
                                            }
                                        Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2,reservesSpace:true)
                                        HStack {
                                            Text(book.displayAuthor).lineLimit(1)
                                            Spacer(minLength:2)
                                            if !book.locator.isEmpty { Text("\(Int(book.progress * 100))%").monospacedDigit() }
                                        }.font(.caption2).foregroundStyle(.secondary)
                                    }.foregroundStyle(.primary)
                                }.buttonStyle(.plain).contextMenu {
                                    Button("阅读") { open(book) }
                                    if reader.downloadingBook == book.id { Button("取消下载",role:.cancel) { cancelDownload() } }
                                    if book.remoteBookID != nil, reader.isDownloaded(book) { Button("移除下载，保留阅读记录") { reader.removeDownload(book) } }
                                    Button("从书库隐藏") { reader.remove(book) }
                                }
                            }
                        }
                        }.padding(.horizontal,24).padding(.vertical,18).frame(maxWidth:isPad ? 1120 : 720).frame(maxWidth:.infinity)
                        if books.isEmpty {
                            ContentUnavailableView {
                                Label(!query.isEmpty ? "没有找到图书" : downloadedOnly ? "暂无已下载图书" : "你的书库",systemImage:"books.vertical")
                            } actions: {
                                if downloadedOnly { Button("显示全部图书") { downloadedOnly = false } }
                                else if query.isEmpty { Button("导入书籍") { importing = true }.buttonStyle(.borderedProminent).disabled(reader.importingBooks) }
                                if reader.hasHiddenBooks { Button("恢复隐藏图书") { reader.restoreHiddenBooks() } }
                            }.padding(.top,60)
                        }
                    }
                    .refreshable { await reader.syncMacLibrary() }
                    .safeAreaInset(edge:.bottom) {
                        if let id = reader.downloadingBook, let book = reader.books.first(where: { $0.id == id }) {
                            HStack(spacing:12) {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(book.title).font(.caption).lineLimit(1)
                                    Text("正在下载 \(Int(reader.downloadProgress*100))%").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { cancelDownload() } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("取消下载")
                            }.padding(.leading,16).padding(.trailing,4).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)).padding(.horizontal,16).padding(.bottom,8)
                        }
                    }
                    .background(Color(uiColor:.systemGroupedBackground))
                    .navigationTitle("书库")
                    .searchable(text:$query,prompt:"书名或作者")
                    .toolbar {
                        ToolbarItemGroup(placement:.topBarTrailing) {
                            Button { reader.openKnowledgeWorkspace() } label: { Image(systemName:"point.3.connected.trianglepath.dotted") }.accessibilityLabel("全书脉络与笔记")
                            Button { importing = true } label: { Image(systemName:"plus") }.accessibilityLabel("导入书籍").disabled(reader.importingBooks)
                            Button { if isPad { ipadRemote = true } else { remote = true } } label: { Image(systemName:"applewatch") }.accessibilityLabel("手表遥控")
                            Menu {
                                Toggle("仅显示已下载",isOn:$downloadedOnly)
                                Picker("排序",selection:$sortByTitle) { Text("最近阅读").tag(false); Text("书名").tag(true) }
                                Divider()
                                Button("刷新书库",systemImage:"arrow.clockwise") { Task { await reader.syncMacLibrary() } }.disabled(reader.syncingLibrary)
                                Button("Mac 书库",systemImage:"desktopcomputer") { librarySettings = true }
                                Button("阅读进度同步",systemImage:"icloud") { reader.showProgressSettings = true }
                                if reader.hasHiddenBooks { Button("恢复隐藏图书") { reader.restoreHiddenBooks() } }
                            } label: { Image(systemName:"ellipsis") }.accessibilityLabel("书库选项")
                        }
                    }
                }
            }
        }
        .tint(readingAccent)
        .fullScreenCover(isPresented:Binding(get:{ !isPad && reader.showNoteGraph },set:{ if !isPad { reader.showNoteGraph = $0 } })) { ReaderNotesScene(reader:reader) }
        .fullScreenCover(item:Binding(get:{ isPad ? nil : reader.selectionDiscussion },set:{ if !isPad { reader.selectionDiscussion = $0 } })) { draft in
            ReaderSelectionDiscussion(reader:reader,draft:draft) { reader.selectionDiscussion = nil }
                .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
        }
        .onDisappear { downloadTask?.cancel() }
        .fileImporter(isPresented:$importing,allowedContentTypes:BookFormat.allCases.map(\.contentType),allowsMultipleSelection:true) { result in
            switch result {
            case .success(let urls): reader.importBooks(urls)
            case .failure(let error): reader.error = error.localizedDescription
            }
        }
        .sheet(isPresented:$librarySettings,onDismiss:{ Task { await reader.syncMacLibrary() } }) { MacLibrarySetup() }
        .sheet(isPresented:$ipadRemote) { IPadRemoteSetup(receiver:ipadReceiver) }
        .sheet(isPresented:$reader.showProgressSettings) { ProgressSyncView(reader:reader) }
        .sheet(isPresented:$remote,onDismiss:{ Task { await reader.syncProgress(); await reader.syncMacLibrary(); await PhoneRelay.shared.refresh() } }) { PhoneRemoteView() }
        .alert("无法完成操作",isPresented:Binding(get:{reader.error != nil && !reader.showNoteGraph && reader.selectionDiscussion == nil},set:{if !$0 && !reader.showNoteGraph && reader.selectionDiscussion == nil { reader.error = nil }})) {
            Button("好") { reader.error = nil }
        } message: { Text(reader.error ?? "") }
        .alert("导入结果",isPresented:Binding(get:{reader.importMessage != nil},set:{if !$0 { reader.importMessage = nil }})) {
            Button("完成") { reader.importMessage = nil }
        } message: { Text(reader.importMessage ?? "") }
        .overlay(alignment:.bottom) {
            if reader.importingBooks { ProgressView("正在导入…").padding(16).background(.regularMaterial,in:Capsule()).padding() }
        }
        .onOpenURL { reader.importBooks([$0]) }
        .onAppear {
            if isPad { ipadReceiver.resume() }
            else { PhoneRelay.shared.configureLocal(reader) }
            #if DEBUG
            importStagedBook()
            #endif
        }
        .task { if !isPad { await PhoneRelay.shared.refresh() } }
        .task { libraryConnection.startDiscovery(); await reader.syncMacLibrary() }
        .task { await reader.syncProgress() }
        .onChange(of:libraryConnection.connection) { _,_ in Task { await reader.syncMacLibrary() } }
        .onChange(of:libraryConnection.catalogRevision) { _,_ in Task { await reader.syncMacLibrary() } }
        .onChange(of:scenePhase) { _,phase in
            if phase != .active { reader.save(); reader.flushProgressInBackground(); if phase == .background { ipadReceiver.suspend(); libraryConnection.stopDiscovery() } }
            else {
                ipadReceiver.resume()
                libraryConnection.startDiscovery()
                if !isPad { Task { await PhoneRelay.shared.refresh() } }
                Task { await reader.syncProgress() }
                Task { await reader.syncMacLibrary() }
            }
        }
    }
    private func open(_ book: LibraryBook) {
        guard reader.downloadingBook == nil else { return }
        downloadTask = Task { await reader.openFromLibrary(book.id) }
    }
    private func cancelDownload() {
        downloadTask?.cancel(); reader.knowledgeOpenTask?.cancel()
    }
    #if DEBUG
    // Development installs can deliver an EPUB through the same importer as Files.
    // Only a single filename inside this app's Documents directory is accepted.
    @State private var stagedImportStarted = false
    private func importStagedBook() {
        guard !stagedImportStarted else { return }
        stagedImportStarted = true
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of:"--bookslide-import-epub"), args.indices.contains(index + 1) else { return }
        let name = args[index + 1]
        guard !name.isEmpty, (name as NSString).lastPathComponent == name,
              (name as NSString).pathExtension.lowercased() == "epub",
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        reader.importBooks([documents.appendingPathComponent(name)])
    }
    #endif

}
