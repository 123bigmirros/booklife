import SwiftUI

/// A compact reading home, with books and saved thoughts on one quiet surface.
struct IPadLibraryView: View {
    @ObservedObject var reader: ReaderModel
    let importBooks: () -> Void
    let showRemote: () -> Void
    let showMacLibrary: () -> Void
    let open: (LibraryBook) -> Void
    let cancelDownload: () -> Void
    @State private var destination: Destination = .reading
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var sortByTitle = false
    @State private var listView = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Destination: String, CaseIterable, Identifiable {
        case reading = "现在阅读", library = "全部图书", downloaded = "已下载"
        var id: Self { self }
        var symbol: String {
            switch self { case .reading: "book"; case .library: "books.vertical"; case .downloaded: "arrow.down.circle" }
        }
    }
    private var books: [LibraryBook] {
        let search = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return reader.visibleBooks.filter {
            (destination != .downloaded || reader.isDownloaded($0)) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.author.localizedCaseInsensitiveContains(search))
        }.sorted { sortByTitle ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.lastRead > $1.lastRead }
    }
    private var isHome: Bool { destination == .reading && query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private var currentRead: LibraryBook? {
        reader.visibleBooks.filter { !$0.locator.isEmpty && $0.progress < 1 }.max { $0.lastRead < $1.lastRead }
    }
    private var featured: LibraryBook? { currentRead ?? reader.sampleBook ?? books.first }
    private var shelfBooks: [LibraryBook] {
        isHome ? Array(books.filter { $0.id != featured?.id }.prefix(6)) : books
    }

    private var paper: Color {
        colorScheme == .dark ? Color(uiColor:.systemBackground) : Color(red:0.985,green:0.98,blue:0.965)
    }
    private var accent: Color {
        colorScheme == .dark ? Color(red:0.71,green:0.81,blue:0.73) : Color(red:0.24,green:0.34,blue:0.28)
    }
    private var recentThought: ReaderAnnotation? {
        featured?.annotations?.filter { !$0.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            .max { $0.updatedAt < $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let narrow = geometry.size.width < 760 || typeSize.isAccessibilitySize
                VStack(spacing:0) {
                    topBar(compact:narrow)
                        .padding(.horizontal,geometry.size.width < 600 ? 24 : 48)
                        .padding(.vertical,12).frame(maxWidth:1100).frame(maxWidth:.infinity)
                    Divider().opacity(0.5)
                    ScrollView {
                        VStack(alignment:.leading,spacing:28) {
                            if !isHome || searchVisible { pageHeading(compact:narrow) }
                            libraryStatus
                            if isHome, let featured {
                                featuredBook(featured,compact:geometry.size.width < 900 || typeSize.isAccessibilitySize)
                                Divider().opacity(0.55)
                            }
                            shelf
                        }
                        .padding(.horizontal,geometry.size.width < 600 ? 24 : 48)
                        .padding(.top,32).padding(.bottom,40)
                        .frame(maxWidth:1100).frame(maxWidth:.infinity)
                    }
                    .refreshable { await reader.syncMacLibrary() }
                }.background(paper)
            }
            .toolbar(.hidden,for:.navigationBar)
            .safeAreaInset(edge:.bottom) { downloadStatus }
        }.tint(accent)
    }

    private func topBar(compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:32) {
                HStack(spacing:9) {
                    Image(systemName:"book.closed").font(.system(size:19,weight:.regular))
                    Text("书籍人生").font(.system(size:23,weight:.medium,design:.serif))
                }.fixedSize(horizontal:true,vertical:false).foregroundStyle(.primary)
                    .accessibilityElement(children:.combine)
                if !compact { navigation }
                Spacer(minLength:8)
                HStack(spacing:6) {
                    Button { searchVisible = true; searchFocused = true } label: {
                        Image(systemName:"magnifyingglass").font(.system(size:18)).frame(width:44,height:44).contentShape(Rectangle())
                    }.accessibilityLabel("搜索书库")
                    Button(action:importBooks) {
                        Label("导入",systemImage:"plus").font(.subheadline).padding(.horizontal,10).frame(minHeight:44).contentShape(Rectangle())
                    }.disabled(reader.importingBooks).accessibilityLabel("导入书籍")
                    libraryMenu
                }.buttonStyle(.plain)
            }
            if compact { navigation }
        }
    }

    private var navigation: some View {
        HStack(spacing:26) {
            ForEach([Destination.reading,.library]) { item in
                let selected = destination == item || (item == .library && destination == .downloaded)
                Button {
                    destination = item; query = ""; searchVisible = false; searchFocused = false
                } label: {
                    Text(item == .reading ? "阅读" : "书库")
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(minWidth:44,minHeight:44).contentShape(Rectangle())
                        .overlay(alignment:.bottom) {
                            if selected { Capsule().fill(accent).frame(width:20,height:2) }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button { reader.openKnowledgeWorkspace() } label: {
                Text("笔记").font(.subheadline).foregroundStyle(.secondary).frame(minWidth:44,minHeight:44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("脉络与笔记").disabled(reader.visibleBooks.isEmpty)
        }
    }

    private func pageHeading(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment:.leading,spacing:16)) : AnyLayout(HStackLayout(alignment:.center,spacing:24))
        return layout {
            if !isHome {
                Text(query.isEmpty ? (destination == .downloaded ? "已下载" : "我的书库") : "搜索结果")
                    .font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索书名或作者",text:$query).textFieldStyle(.plain).submitLabel(.search)
                    .focused($searchFocused).accessibilityLabel("搜索书名或作者")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary).frame(width:44,height:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
                if destination == .reading {
                    Button("取消") { query = ""; searchVisible = false; searchFocused = false }.frame(minHeight:44)
                }
            }.font(.subheadline).padding(.leading,14).padding(.trailing,6).frame(minHeight:44)
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                .frame(maxWidth:compact || isHome ? .infinity : 320)
        }
    }

    @ViewBuilder private var libraryStatus: some View {
        if reader.syncingLibrary {
            ProgressView("正在刷新书库…").font(.caption).controlSize(.small)
        } else if let message = reader.libraryMessage {
            HStack(spacing:12) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("重试") { Task { await reader.syncMacLibrary() } }
                    .font(.caption.weight(.medium)).frame(minWidth:44,minHeight:44)
            }
        }
    }

    private func featuredBook(_ book: LibraryBook,compact: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:24)) : AnyLayout(HStackLayout(alignment:.center,spacing:32))
        return layout {
            Button { open(book) } label: {
                jacket(book).frame(width:compact ? 100 : 128)
            }.buttonStyle(.plain).accessibilityLabel("继续阅读\(book.title)")
            featuredDetails(book).frame(maxWidth:.infinity,alignment:.leading)
            if !compact, let note = recentThought {
                HStack(spacing:26) {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width:1,height:136)
                    Button { reader.openKnowledgeWorkspace(bookID:book.id,noteID:note.id) } label: {
                        VStack(alignment:.leading,spacing:12) {
                            Text("最近的想法").font(.caption).foregroundStyle(.secondary)
                            let heading = note.title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                            Text(heading.isEmpty ? String(note.note.split(separator:"\n").first ?? "阅读笔记") : heading)
                                .font(.system(.title3,design:.serif).weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                            let text = heading.isEmpty ? note.note.split(separator:"\n").dropFirst().joined(separator:"\n") : note.note
                            if !text.isEmpty { Text(text).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4).lineLimit(2) }
                            Label("继续整理",systemImage:"arrow.up.right").font(.caption).foregroundStyle(accent).padding(.top,4)
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("继续编辑最近笔记")
                }.frame(width:260)
            }
        }.padding(.vertical,4)
    }

    private func featuredDetails(_ book: LibraryBook) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text(book.locator.isEmpty ? "从这本开始" : "接着上次，继续读").font(.caption).foregroundStyle(.secondary)
            Text(book.title).font(.system(.largeTitle,design:.serif).weight(.medium)).lineLimit(3)
                .foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
            Text(book.displayAuthor.isEmpty ? (book.format?.label ?? "电子书") : book.displayAuthor).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if !book.locator.isEmpty {
                HStack(spacing:10) {
                    ProgressView(value:book.progress).tint(accent).frame(width:96)
                    Text("已读 \(Int(book.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.top,4)
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:20) { readButton(book); bookNotesButton(book) }
                VStack(alignment:.leading,spacing:8) { readButton(book); bookNotesButton(book) }
            }.padding(.top,6)
        }
    }

    private func readButton(_ book: LibraryBook) -> some View {
        Button { open(book) } label: {
            Label(book.locator.isEmpty ? "开始阅读" : "继续阅读",systemImage:"arrow.right")
                .font(.subheadline.weight(.semibold)).padding(.horizontal,18).frame(height:44)
                .foregroundStyle(Color(uiColor:.systemBackground)).background(Color.primary,in:RoundedRectangle(cornerRadius:10))
                .contentShape(RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain).disabled(reader.downloadingBook != nil)
            .accessibilityIdentifier("library-open-featured")
            .opacity(reader.downloadingBook == nil ? 1 : 0.45)
    }

    private func bookNotesButton(_ book: LibraryBook) -> some View {
        Button { reader.openKnowledgeWorkspace(bookID:book.id) } label: {
            Label("阅读笔记",systemImage:"square.and.pencil").font(.subheadline)
                .frame(minHeight:44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
    }

    private var shelf: some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(alignment:.firstTextBaseline) {
                Text(isHome ? "我的书架" : "\(books.count) 本图书").font(.title3.weight(.medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                if isHome {
                    Button("全部 \(reader.visibleBooks.count) 本 →") { destination = .library }.font(.subheadline).frame(minHeight:44)
                } else {
                    Menu {
                        Picker("排序",selection:$sortByTitle) { Text("最近阅读").tag(false); Text("书名").tag(true) }
                        Toggle("列表显示",isOn:$listView)
                    } label: { Label(sortByTitle ? "书名" : "最近阅读",systemImage:listView ? "list.bullet" : "square.grid.2x2") }
                        .font(.subheadline).accessibilityLabel("图书排序与显示方式")
                }
            }
            if isHome && shelfBooks.isEmpty && featured != nil {
                Button(action:importBooks) {
                    HStack(spacing:16) {
                        Image(systemName:"plus").font(.system(size:20,weight:.light))
                            .frame(width:48,height:58).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:8))
                        VStack(alignment:.leading,spacing:5) {
                            Text("添加下一本书").font(.subheadline.weight(.medium))
                            Text("导入 EPUB 或 PDF，开始新的阅读").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName:"arrow.up.doc").font(.subheadline).foregroundStyle(.secondary)
                    }.foregroundStyle(.primary).padding(.vertical,12).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(reader.importingBooks).accessibilityLabel("导入下一本书")
            } else if books.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? (destination == .downloaded ? "暂无已下载图书" : "你的下一本好书，从这里开始") : "没有找到图书",systemImage:"books.vertical")
                } description: {
                    Text(query.isEmpty ? "导入 EPUB 或 PDF，或从 Mac 书库获取图书。" : "试试其他书名或作者。")
                } actions: {
                    if destination == .downloaded { Button("查看全部图书") { destination = .library } }
                    else if query.isEmpty { Button("导入图书",action:importBooks).buttonStyle(.borderedProminent).disabled(reader.importingBooks) }
                }.padding(.vertical,24)
            } else if listView && !isHome {
                LazyVStack(spacing:0) {
                    ForEach(books) { book in
                        bookButton(book,list:true)
                        Divider().padding(.leading,80)
                    }
                }
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:typeSize.isAccessibilitySize ? 180 : 140,maximum:typeSize.isAccessibilitySize ? 200 : 156),spacing:28)],alignment:.leading,spacing:30) {
                    ForEach(shelfBooks) { book in bookButton(book,list:false) }
                }
            }
        }.padding(.top,8)
    }

    private func bookButton(_ book: LibraryBook,list: Bool) -> some View {
        Button { open(book) } label: {
            Group {
                if list {
                    HStack(spacing:20) {
                        jacket(book).frame(width:60)
                        bookCaption(book)
                        Spacer()
                        Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical,16)
                } else {
                    VStack(alignment:.leading,spacing:12) { jacket(book); bookCaption(book) }
                        .frame(width:typeSize.isAccessibilitySize ? 170 : 132,alignment:.leading)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }
            }.foregroundStyle(.primary).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(book.title)，\(book.author)，\(reader.isDownloaded(book) ? "已下载" : "可下载")\(book.locator.isEmpty ? "" : "，已读 \(Int(book.progress * 100))%")")
            .contextMenu {
                Button("阅读",systemImage:"book") { open(book) }
                Button("脉络与笔记",systemImage:"point.3.connected.trianglepath.dotted") { reader.openKnowledgeWorkspace(bookID:book.id) }
                if reader.downloadingBook == book.id { Button("取消下载",role:.cancel,action:cancelDownload) }
                if book.remoteBookID != nil, reader.isDownloaded(book) { Button("移除下载，保留阅读记录",systemImage:"arrow.down.circle") { reader.removeDownload(book) } }
                Button("从书库隐藏",systemImage:"eye.slash") { reader.remove(book) }
            }
    }

    private func jacket(_ book: LibraryBook) -> some View {
        BookJacket(reader:reader,book:book,style:.plain).overlay(alignment:.bottomTrailing) {
            if reader.downloadingBook == book.id {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.25),lineWidth:2)
                    Circle().trim(from:0,to:reader.downloadProgress).stroke(readingAccent,style:StrokeStyle(lineWidth:2,lineCap:.round)).rotationEffect(.degrees(-90))
                }.frame(width:22,height:22).padding(8).background(.regularMaterial,in:Circle()).padding(6)
            } else if !reader.isDownloaded(book) {
                Image(systemName:"icloud.and.arrow.down").font(.system(size:14)).padding(8).background(.regularMaterial,in:Circle()).padding(6)
            }
        }
    }

    private func bookCaption(_ book: LibraryBook) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(book.title).font(.system(size:14,weight:.medium)).lineLimit(2,reservesSpace:true)
            Text(book.displayAuthor.isEmpty ? (book.format?.label ?? "电子书") : book.displayAuthor).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1)
            if !book.locator.isEmpty {
                Text(book.progress >= 1 ? "已读完" : "已读 \(Int(book.progress * 100))%")
                    .font(.system(size:11)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private var libraryMenu: some View {
        Menu {
            Button("刷新书库",systemImage:"arrow.clockwise") { Task { await reader.syncMacLibrary() } }.disabled(reader.syncingLibrary)
            Button(destination == .downloaded ? "显示全部图书" : "只看已下载",systemImage:"arrow.down.circle") { destination = destination == .downloaded ? .library : .downloaded }
            if reader.hasHiddenBooks { Button("恢复隐藏图书",systemImage:"eye") { reader.restoreHiddenBooks() } }
            Divider()
            Menu("连接与同步",systemImage:"slider.horizontal.3") {
                Button("Mac 书库",systemImage:"desktopcomputer",action:showMacLibrary)
                Button("手表遥控",systemImage:"applewatch",action:showRemote)
                Button("阅读进度同步",systemImage:"icloud") { reader.showProgressSettings = true }
            }
        } label: { Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("书库选项")
    }

    @ViewBuilder private var downloadStatus: some View {
        if let id = reader.downloadingBook, let book = reader.books.first(where: { $0.id == id }) {
            HStack(spacing:14) {
                ProgressView(value:reader.downloadProgress).frame(width:80)
                Text("正在下载 · \(book.title)").font(.subheadline).lineLimit(1)
                Spacer()
                Text("\(Int(reader.downloadProgress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(action:cancelDownload) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("取消下载")
            }.padding(.leading,20).padding(.trailing,6).background(.regularMaterial,in:Capsule())
                .padding(.horizontal,24).padding(.bottom,12)
        }
    }
}
