import SwiftUI
import AppKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

private let forest = Color(red:0.25,green:0.39,blue:0.31)

private struct ReadingWindowTracker: NSViewRepresentable {
    var changed: (Bool, Bool, Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { let view = TrackingView(); view.changed = changed; return view }
    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }
    final class TrackingView: NSView {
        var changed: ((Bool, Bool, Bool) -> Void)?
        private var observer: [NSObjectProtocol] = []
        private var monitor: Any?
        private var last: (Bool, Bool, Bool)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.forEach(NotificationCenter.default.removeObserver); observer = []
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didResizeNotification, NSWindow.didResignKeyNotification] {
                observer.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in self?.report() })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged]) { [weak self] event in
                self?.report(); return event
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }
        func report() {
            guard let window, let content = window.contentView else { return }
            let full = window.styleMask.contains(.fullScreen)
            let point = content.convert(window.mouseLocationOutsideOfEventStream,from:nil)
            let inside = content.bounds.contains(point) && window.isKeyWindow
            let fromTop = content.isFlipped ? point.y-content.bounds.minY : content.bounds.maxY-point.y
            let fromBottom = content.bounds.height-fromTop
            let top = inside && fromTop < 90
            let bottom = inside && fromBottom < 65
            guard last == nil || last!.0 != full || last!.1 != top || last!.2 != bottom else { return }
            last = (full,top,bottom); changed?(full,top,bottom)
        }
        deinit {
            observer.forEach(NotificationCenter.default.removeObserver)
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

struct ReaderWindow: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var receiver: ReceiverModel
    @State private var showConnection = false
    @State private var showAppearance = false
    @State private var sidebar = false
    @State private var fullScreen = false
    @State private var nearTop = false
    @State private var nearBottom = false
    private var topVisible: Bool { !fullScreen || reader.currentID == nil || nearTop || showAppearance || showConnection || sidebar }
    private var bottomVisible: Bool { !fullScreen || nearBottom }
    @State private var query = ""
    @State private var tab = 0
    @State private var libraryQuery = ""
    @State private var sortByTitle = false
    @State private var librarySource = 0
    @State private var connectionHelp = false
    private var libraryBooks: [LibraryBook] {
        let query = libraryQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        return reader.visibleBooks.filter {
            (librarySource == 0 || (librarySource == 1 ? $0.sourcePath == nil : $0.sourcePath != nil)) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query))
        }.sorted { sortByTitle ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.lastRead > $1.lastRead }
    }
    var body: some View {
        VStack(spacing:0) {
            topbar.opacity(topVisible ? 1 : 0).allowsHitTesting(topVisible).accessibilityHidden(!topVisible)
            if reader.currentID == nil { library }
            else { reading }
        }
        .background(reader.appearance.background)
        .foregroundStyle(reader.appearance.ink)
        .tint(forest)
        .frame(minWidth:620,minHeight:480)
        .ignoresSafeArea(.container,edges:.top)
        .background(ReadingWindowTracker { active, top, bottom in
            if active && !fullScreen { sidebar = false }
            fullScreen = active; nearTop = top; nearBottom = bottom
        })
        .animation(.easeOut(duration:0.18),value:topVisible)
        .animation(.easeOut(duration:0.18),value:bottomVisible)
        .preferredColorScheme(reader.appearance.theme == "night" ? .dark : .light)
        .sheet(isPresented:$reader.showProgressSettings) { ProgressSyncView(reader:reader) }
        .sheet(isPresented:$showConnection) { connection }
        .onChange(of:receiver.pending?.id) { value in if value != nil { showConnection = true } }
        .onChange(of:reader.appearance) { _ in reader.updateAppearance() }
        .alert("阅读提示",isPresented:Binding(get:{reader.error != nil},set:{if !$0 { reader.error = nil }})) { Button("知道了") { reader.error = nil } } message: { Text(reader.error ?? "") }
        .alert("导入结果",isPresented:Binding(get:{reader.importMessage != nil},set:{if !$0 { reader.importMessage = nil }})) {
            Button("完成") { reader.importMessage = nil }
        } message: { Text(reader.importMessage ?? "") }
        .onChange(of:reader.currentID) { _ in query = ""; sidebar = false; tab = 0 }

    }
    private var topbar: some View {
        GeometryReader { geometry in
            HStack(spacing:14) {
                Color.clear.frame(width:58,height:1)
                if reader.currentID != nil {
                    HStack(spacing:6) {
                        icon("books.vertical", "返回书库") { reader.close() }
                        icon("list.bullet", "目录与书签") { sidebar.toggle() }
                        icon("point.3.connected.trianglepath.dotted", "全书脉络与笔记") { reader.openNoteGraph() }
                        icon("magnifyingglass", "搜索") { tab = 2; sidebar = true }
                    }.padding(.horizontal,10).padding(.vertical,5).background(controlSurface)
                } else { Text("书库").font(.system(size:17,weight:.semibold)) }
                Spacer()
                if reader.currentID == nil {
                    Button { reader.openKnowledgeWorkspace() } label: { Label("脉络与笔记",systemImage:"point.3.connected.trianglepath.dotted") }
                    Button { reader.chooseImport() } label: {
                        Label(reader.importingBooks ? "正在导入…" : "导入书籍",systemImage:"plus")
                    }.disabled(reader.importingBooks)
                    Button { showConnection = true } label: { Label("手表遥控",systemImage:"applewatch") }
                    Menu {
                        Button("阅读进度同步") { reader.showProgressSettings = true }
                        Button("刷新 Apple Books 书库") { reader.refreshAppleBooks() }
                        if reader.hasHiddenBooks { Button("恢复隐藏图书") { reader.restoreHiddenBooks() } }
                    } label: { Image(systemName:"ellipsis").frame(width:30,height:30) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多书库选项")

                } else {
                    HStack(spacing:6) {
                        Button { showAppearance.toggle() } label: { Image(systemName:"textformat.size").frame(width:30,height:30) }
                            .buttonStyle(.plain).help("阅读外观").accessibilityLabel("阅读外观")
                            .popover(isPresented:$showAppearance) { appearance }
                        icon(reader.isBookmarked ? "bookmark.fill" : "bookmark",reader.isBookmarked ? "移除书签" : "添加书签") { reader.toggleBookmark() }
                        Menu {
                            Button("随手记",systemImage:"square.and.pencil") { reader.beginQuickNote() }
                            Divider()
                            Button("手表遥控") { showConnection = true }
                        Button("阅读进度同步") { reader.showProgressSettings = true }
                        } label: { Image(systemName:"ellipsis").frame(width:30,height:30) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多阅读选项")
                    }.padding(.horizontal,10).padding(.vertical,5).background(controlSurface)
                }
            }.padding(.horizontal,18).frame(height:56)
                .overlay {
                    if reader.currentID != nil {
                        Text(reader.currentBook?.title ?? "").font(.system(size:13,weight:.medium))
                            .lineLimit(1).frame(maxWidth:max(40,geometry.size.width-580)).allowsHitTesting(false)
                    }
                }
        }.frame(height:56)
    }
    private var controlSurface: some View {
        Capsule().fill(reader.appearance.theme == "night" ? Color.white.opacity(0.06) : Color.white.opacity(0.26))
            .overlay(Capsule().strokeBorder(reader.appearance.ink.opacity(0.1),lineWidth:0.5))
            .shadow(color:reader.appearance.ink.opacity(0.035),radius:8,y:2)
    }
    private func icon(_ symbol: String,_ label: String,action:@escaping () -> Void) -> some View {
        Button(action:action) { Image(systemName:symbol).frame(width:30,height:30).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private var library: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                if libraryQuery.isEmpty, librarySource == 0,
                   let recent = reader.visibleBooks.filter({ !$0.locator.isEmpty && $0.progress < 1 }).max(by: { $0.lastRead < $1.lastRead }) {
                    Button { reader.open(recent.id) } label: {
                        HStack(spacing:18) {
                            BookJacket(reader:reader,book:recent).frame(width:54)
                            VStack(alignment:.leading,spacing:6) {
                                Text("继续阅读").font(.caption).foregroundStyle(.secondary)
                                Text(recent.title).font(.headline).lineLimit(2)
                                Text("已读 \(Int(recent.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName:"chevron.right").foregroundStyle(.secondary)
                        }.padding(16).background(forest.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain)
                }
                if libraryQuery.isEmpty, librarySource == 0, !reader.visibleBooks.contains(where: { !$0.locator.isEmpty }), let sample = reader.sampleBook {
                    HStack(spacing:16) {
                        VStack(alignment:.leading,spacing:6) {
                            Text("从一小段阅读开始").font(.headline)
                            Text("先读示例，也可以导入自己的 EPUB。").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("试读示例") { reader.open(sample.id) }.buttonStyle(.borderedProminent)
                    }.padding(18).background(forest.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
                }
                HStack {
                    Text("全部图书").font(.system(size:24,weight:.semibold,design:.serif))
                    Text("\(libraryBooks.count) 本").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength:12)
                    TextField("书名或作者",text:$libraryQuery).textFieldStyle(.roundedBorder).frame(maxWidth:220)
                        .accessibilityLabel("搜索书库")
                    Menu {
                        Picker("排序",selection:$sortByTitle) { Text("最近阅读").tag(false); Text("书名").tag(true) }
                        Picker("来源",selection:$librarySource) { Text("全部图书").tag(0); Text("导入的图书").tag(1); Text("Apple Books").tag(2) }
                    } label: { Image(systemName:"line.3.horizontal.decrease.circle") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("排序与筛选")
                }
                if librarySource != 0 {
                    HStack {
                        Text(librarySource == 1 ? "仅显示导入的图书" : "仅显示 Apple Books").font(.caption).foregroundStyle(.secondary)
                        Button("显示全部") { librarySource = 0 }.font(.caption)
                    }
                }
                if reader.needsAppleBooksFolder {
                    HStack {
                        Text("已有 Apple Books 图书？").font(.callout).foregroundStyle(.secondary)
                        Button("连接书库") { reader.chooseAppleBooksFolder() }
                    }
                }
                if libraryBooks.isEmpty {
                    VStack(spacing:14) {
                        Image(systemName:reader.visibleBooks.isEmpty ? "books.vertical" : "magnifyingglass").font(.system(size:36,weight:.light))
                        Text(reader.visibleBooks.isEmpty ? "从第一本书开始" : "没有找到图书").font(.title3)
                        if !libraryQuery.isEmpty || librarySource != 0 {
                            Button("显示全部图书") { libraryQuery = ""; librarySource = 0 }
                        } else {
                            Text("支持无 DRM 的 EPUB 文件").font(.callout).foregroundStyle(.secondary)
                            Button("导入书籍") { reader.chooseImport() }.buttonStyle(.borderedProminent).disabled(reader.importingBooks)
                            if reader.hasHiddenBooks { Button("恢复隐藏图书") { reader.restoreHiddenBooks() } }
                        }
                    }.frame(maxWidth:.infinity).padding(.vertical,60)
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150,maximum:185),spacing:36)],alignment:.leading,spacing:32) {
                    ForEach(libraryBooks) { book in
                        Button { reader.open(book.id) } label: {
                            VStack(alignment:.leading,spacing:10) {
                                BookJacket(reader:reader,book:book)
                                Text(book.title).font(.callout.weight(.medium)).lineLimit(2).frame(height:36,alignment:.topLeading)
                                HStack {
                                    Text(book.author == "EPUB" ? "" : book.author).lineLimit(1)
                                    Spacer(minLength:4)
                                    if !book.locator.isEmpty { Text("\(Int(book.progress * 100))%").monospacedDigit() }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).contextMenu {
                            Button("阅读") { reader.open(book.id) }
                            Button("从书库隐藏") { reader.remove(book) }
                        }
                    }
                }
            }.padding(32).frame(maxWidth:1120).frame(maxWidth:.infinity,alignment:.center)
        }
    }
    private var reading: some View {
        HStack(spacing:0) {
            if sidebar { contents.frame(width:tab == 3 ? 310 : 270); Divider() }
            VStack(spacing:0) {
                ZStack {
                    GeometryReader { geometry in
                        BookCanvas(reader:reader)
                            .frame(width:max(200,geometry.size.width * (reader.supportsReflow ? 1 - reader.appearance.sideInset / 50 : 1)),height:max(100,geometry.size.height - 48))
                            .position(x:geometry.size.width / 2,y:geometry.size.height / 2)
                    }
                    VStack { SharedProgressPrompt(reader:reader); Spacer() }
                    if reader.loading {
                        ProgressView("正在排版…").controlSize(.small).padding(20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    }
                    if let notice = reader.readingNotice {
                        VStack { Spacer(); Text(notice).font(.caption).padding(10).background(.regularMaterial,in:Capsule()).padding(.bottom,8) }.allowsHitTesting(false)
                    }
                }
                HStack {
                    Button { turn(.previous) } label: { Image(systemName:reader.isScrolling ? "chevron.up" : "chevron.left").frame(width:44,height:40) }.buttonStyle(.plain).accessibilityLabel(reader.readingMode.previousLabel).disabled(reader.position?.canGoPrevious != true || reader.busy)
                        .opacity(bottomVisible ? 0.6 : 0).allowsHitTesting(bottomVisible).accessibilityHidden(!bottomVisible)
                    Spacer()
                    Text(reader.positionLabel).font(.system(size:11)).monospacedDigit().foregroundStyle(reader.appearance.ink.opacity(0.7)).accessibilityLabel(reader.isScrolling ? "阅读进度" : "页码").accessibilityValue(reader.positionLabel)
                    Spacer()
                    Button { turn(.next) } label: { Image(systemName:reader.isScrolling ? "chevron.down" : "chevron.right").frame(width:44,height:40) }.buttonStyle(.plain).accessibilityLabel(reader.readingMode.nextLabel).disabled(reader.position?.canGoNext != true || reader.busy)
                        .opacity(bottomVisible ? 0.6 : 0).allowsHitTesting(bottomVisible).accessibilityHidden(!bottomVisible)
                }.padding(.horizontal,28).padding(.bottom,6)
            }
        }
    }
    private func turn(_ direction: PageDirection) { Task { @MainActor in await reader.turnLocally(direction) } }
    private var contents: some View {
        VStack(alignment:.leading,spacing:16) {
            Button { reader.openNoteGraph() } label: { Label("全书脉络与笔记", systemImage: "point.3.connected.trianglepath.dotted") }
            Picker("导航",selection:$tab) { Text("目录").tag(0); Text("书签").tag(1); Text("搜索").tag(2) }.pickerStyle(.segmented)
            Group {
                if tab == 2 {
                    TextField("搜索书中内容…",text:$query).textFieldStyle(.roundedBorder).onSubmit { reader.search(query) }.onChange(of:query) { _ in reader.search("") }
                    Button("搜索") { reader.search(query) }.disabled(ReaderSearchState.normalized(query).isEmpty || reader.searching)
                    if reader.searching { ProgressView("正在搜索…").controlSize(.small) }
                    else if let message = reader.searchState.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                ScrollView {
                    VStack(alignment:.leading,spacing:4) {
                        if tab == 1 {
                            if reader.currentBook?.bookmarks.isEmpty != false { Text("把喜欢的一页留下来。\n点击上方书签，随时回来。").font(.callout).foregroundStyle(.secondary).padding(.top,20) }
                            ForEach(reader.currentBook?.bookmarks ?? []) { item in
                                Button { reader.go(item.id,viewport:item.viewport) } label: {
                                    VStack(alignment:.leading,spacing:5) { Text(item.title); Text("\(Int(item.progress * 100))%").font(.caption).foregroundStyle(.secondary) }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                                }.buttonStyle(.plain)
                            }
                        } else {
                            ForEach(tab == 0 ? reader.chapters : reader.results) { item in
                                Button { reader.go(item.href) } label: {
                                    Text(item.title).font(.callout).lineLimit(tab == 2 ? 4 : 2).multilineTextAlignment(.leading)
                                        .padding(.vertical,10).padding(.leading,CGFloat(min(item.depth,3))*12+10).padding(.trailing,8).frame(maxWidth:.infinity,alignment:.leading)
                                        .background(reader.position?.chapter == item.title ? forest.opacity(0.09) : .clear,in:RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain)
                            }
                            if tab == 0 && reader.chapters.isEmpty { Text("这本书没有提供目录").font(.callout).foregroundStyle(.secondary) }

                        }
                    }
                }
            }
        }.padding(18)
    }
    private var appearance: some View { ReadingAppearanceView(reader:reader).frame(width:310) }
    private var connection: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Label("手表遥控",systemImage:"applewatch").font(.title2.weight(.medium))
                Spacer()
                Button("完成") { showConnection = false }.keyboardShortcut(.defaultAction)
            }
            Text("在 Apple Watch 打开书籍人生，轻点或转动表冠即可阅读。").font(.callout).foregroundStyle(.secondary)
            Label(receiver.receiverName,systemImage:"desktopcomputer").font(.headline)
            Text(receiver.bluetoothState).font(.callout).foregroundStyle(.secondary)
            if let pending = receiver.pending {
                Text("\(pending.clientName) 请求连接").font(.headline)
                Text(pending.code).font(.system(size:36,weight:.medium,design:.monospaced)).tracking(6)
                Text("确认与另一台设备上的数字相同。")
                HStack {
                    Button("数字一致，允许连接") { receiver.approve(pending.id) }.buttonStyle(.borderedProminent)
                    Button("取消") { receiver.reject() }
                }
            } else if receiver.pairingOpen {
                ProgressView("在手表选择“\(receiver.receiverName)”").controlSize(.small)
                Text("请在 2 分钟内完成选择，再核对两端数字。").font(.caption).foregroundStyle(.secondary)
                Button("取消连接") { receiver.reject() }
            } else {
                if reader.currentBook != nil {
                    Label(reader.currentBook?.title ?? "",systemImage:"book").lineLimit(2)
                } else {
                    Text("连接后，在书库打开一本书即可试用。").font(.callout)
                    if let sample = reader.sampleBook {
                        Button("打开示例试读") { reader.open(sample.id); showConnection = false }
                    }
                }
                Button("连接新设备") { receiver.beginPairing() }.buttonStyle(.borderedProminent)
                Text("已连接的设备会自动重连，无需重复添加。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            DisclosureGroup("连接遇到问题？",isExpanded:$connectionHelp) {
                VStack(alignment:.leading,spacing:10) {
                    Text("让 Mac 保持唤醒，打开两端蓝牙，并允许书籍人生使用蓝牙。")
                    Text("在手表轻点这台 Mac 的名称即可重连。")
                    Text("要换到 iPad 阅读，打开 iPad 的书籍人生，在手表轻点 iPad 名称。")
                    if !receiver.running { Text(receiver.state) }
                }.font(.callout).foregroundStyle(.secondary).padding(.top,10)
            }
            if receiver.enabled {
                Menu("更多") { Button("暂停遥控") { receiver.stop() } }
            } else { Button("恢复遥控") { receiver.start() } }
        }.padding(24).frame(width:460)
        .onAppear { if !receiver.pairingOpen && receiver.pending == nil { receiver.beginPairing() } }
        .onDisappear { if receiver.pairingOpen { receiver.reject() } }
    }
}
