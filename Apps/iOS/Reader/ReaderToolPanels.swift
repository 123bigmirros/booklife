import SwiftUI

enum ReaderNavigationTab: String, CaseIterable, Identifiable {
    case contents = "目录", bookmarks = "书签"
    var id: Self { self }
}

struct ReaderPanelHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerPanelBack) private var back
    @Environment(\.readerGlassPanel) private var glass
    var body: some View {
        HStack(spacing:12) {
            if let back {
                Button(action:back) {
                    Image(systemName:"chevron.left").font(.system(size:17,weight:.medium))
                        .frame(width:44,height:44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("返回阅读菜单")
                    .accessibilityIdentifier("reader-panel-back")
            }
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength:0)
            Button {
                // Clear the route and dismiss the native presentation as well.
                // Changing popover content must not leave its hosting controller open.
                close()
                dismiss()
            } label: {
                Image(systemName:"xmark").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
                    .frame(width:30,height:30).background(Color.primary.opacity(glass ? 0.055 : 0.07),in:Circle())
                    .frame(width:44,height:44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("关闭面板，继续阅读")
                .accessibilityIdentifier("reader-panel-close").keyboardShortcut(.cancelAction)
        }.padding(.horizontal,22).padding(.top,16).padding(.bottom,12).fixedSize(horizontal:false,vertical:true).layoutPriority(1)
    }
}

struct ReaderAppearancePanel: View {
    @ObservedObject var reader: ReaderModel
    let close: () -> Void
    @State private var advanced = false
    @Environment(\.readerGlassPanel) private var glass
    private var card: Color { glass ? Color.primary.opacity(0.04) : Color(uiColor:.secondarySystemGroupedBackground) }
    private var settings: ReaderAppearance { reader.appearance }
    var body: some View {
        VStack(spacing:0) {
            ReaderPanelHeader(title:"主题与排版",close:close)
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    PDFLayoutControls(reader:reader)
                    if let pdf = reader.pdfBookReader, !reader.isPDFTextLayout {
                        HStack(spacing:20) {
                            Button("缩小",systemImage:"minus.magnifyingglass") { pdf.zoom(by:0.85) }
                            Button("放大",systemImage:"plus.magnifyingglass") { pdf.zoom(by:1.18) }
                        }.frame(maxWidth:.infinity,minHeight:48).background(card,in:Capsule())
                    } else {
                        HStack(spacing:0) {
                            sizeButton("textformat.size.smaller","缩小字号",delta:-1)
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(width:0.5,height:22)
                            sizeButton("textformat.size.larger","放大字号",delta:1)
                        }.background(card,in:Capsule())
                    }
                    VStack(alignment:.leading,spacing:12) {
                        sectionTitle("页面主题")
                        HStack(spacing:10) {
                            theme("light","明亮",.white,Color(white:0.12))
                            theme("paper","纸色",Color(red:242/255,green:227/255,blue:200/255),Color(red:56/255,green:45/255,blue:32/255))
                            theme("night","夜间",Color(red:0.125,green:0.153,blue:0.145),Color(white:0.94))
                        }
                    }
                    VStack(spacing:0) {
                        HStack {
                            Label("阅读方式",systemImage:"book.pages")
                            Spacer()
                            Picker("阅读方式",selection:$reader.appearance.mode) {
                                Text("翻页").tag(ReadingMode.paged)
                                Text("滚动").tag(ReadingMode.scroll)
                            }.pickerStyle(.segmented).frame(width:150)
                        }.padding(16)
                        if reader.supportsReflow || reader.isPDFTextLayout {
                            Divider().padding(.leading,16)
                            HStack {
                                Text("字体")
                                Spacer()
                                Picker("字体",selection:$reader.appearance.font) {
                                    Text("苹方").tag("pingfang"); Text("宋体").tag("serif")
                                    Text("黑体").tag("sans"); Text(reader.isPDFTextLayout ? "系统默认" : "原书字体").tag("publisher")
                                }.labelsHidden().pickerStyle(.menu)
                            }.padding(.horizontal,16).frame(minHeight:54)
                        }
                    }.font(.subheadline).background(card,in:RoundedRectangle(cornerRadius:18))
                    DisclosureGroup(isExpanded:$advanced) {
                        VStack(spacing:18) {
                            if reader.supportsReflow || reader.isPDFTextLayout {
                                labeledSlider("行距",value:$reader.appearance.lineHeight,range:1.3...2.2,step:0.05,display:String(format:"%.2f",settings.lineHeight))
                            }
                            labeledSlider("页边留白",value:$reader.appearance.margin,range:0...96,step:4,display:"\(Int(settings.margin))")
                            Button("重置字体与排版") { reader.resetReaderTypography() }
                                .font(.subheadline).frame(maxWidth:.infinity,minHeight:44)
                        }.padding(.top,20)
                    } label: { Label("排版细节",systemImage:"slider.horizontal.3").font(.subheadline) }
                }.padding(.horizontal,22).padding(.top,8).padding(.bottom,24)
            }
        }.background(glass ? Color.clear : Color(uiColor:.systemGroupedBackground)).tint(readingAccent)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
    private func sizeButton(_ symbol: String,_ label: String,delta: Double) -> some View {
        Button { reader.appearance.fontSize = min(64,max(14,settings.fontSize+delta)) } label: {
            Image(systemName:symbol).font(.system(size:22)).frame(maxWidth:.infinity,minHeight:48)
        }.buttonStyle(.plain).disabled(delta < 0 ? settings.fontSize <= 14 : settings.fontSize >= 64).accessibilityLabel(label)
            .accessibilityValue("当前字号 \(Int(settings.fontSize)) 点")
    }
    private func theme(_ key: String,_ title: String,_ background: Color,_ foreground: Color) -> some View {
        Button { reader.appearance.theme = key } label: {
            VStack(spacing:10) {
                Text("Aa").font(.system(size:25,weight:.medium,design:.serif))
                HStack(spacing:4) {
                    Text(title).font(.caption)
                    if settings.theme == key { Image(systemName:"checkmark").font(.system(size:9,weight:.semibold)) }
                }
            }.foregroundStyle(foreground).frame(maxWidth:.infinity,minHeight:92)
                .background(background,in:RoundedRectangle(cornerRadius:15))
                .overlay(RoundedRectangle(cornerRadius:15).strokeBorder(settings.theme == key ? foreground : .gray.opacity(0.18),lineWidth:settings.theme == key ? 1.5 : 0.5).allowsHitTesting(false))
        }.buttonStyle(.plain).accessibilityLabel("\(title)主题").accessibilityAddTraits(settings.theme == key ? .isSelected : [])
    }
    private func labeledSlider(_ title: String,value: Binding<Double>,range: ClosedRange<Double>,step: Double,display: String) -> some View {
        VStack(spacing:8) {
            HStack { Text(title); Spacer(); Text(display).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value:value,in:range,step:step).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}

struct ReaderNavigationPanel: View {
    @ObservedObject var reader: ReaderModel
    let navigate: (String) -> Void
    let close: () -> Void
    @State var tab: ReaderNavigationTab = .contents
    @State private var removed: ReaderBookmark?
    @State private var failure: String?
    @Environment(\.readerGlassPanel) private var glass
    private var bookmarks: [ReaderBookmark] { (reader.currentBook?.bookmarks ?? []).sorted { $0.progress < $1.progress } }
    private var currentChapter: String? {
        let href = reader.position?.chapterHref ?? reader.position?.anchor?.href
        return reader.chapters.first { chapter in
            if let href { return BookNotesIndex.normalized(chapter.href) == BookNotesIndex.normalized(href) }
            return chapter.title == reader.position?.chapter
        }?.id
    }
    var body: some View {
        VStack(spacing:0) {
            ReaderPanelHeader(title:"目录与书签",subtitle:reader.currentBook?.title,close:close)
            Picker("阅读导航",selection:$tab) { ForEach(ReaderNavigationTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal,22).padding(.bottom,14).fixedSize(horizontal:false,vertical:true).layoutPriority(1)
            if tab == .contents { contents } else { bookmarkList }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(16) }
            if let removed {
                HStack { Text("已移除书签").foregroundStyle(.secondary); Spacer(); Button("撤销") {
                    if bookmarkAction({ reader.setReaderBookmark(removed,present:true) }) { self.removed = nil }
                } }.font(.subheadline).padding(.horizontal,22).frame(minHeight:52).background(.regularMaterial)
            }
        }.background(glass ? Color.clear : Color(uiColor:.systemBackground)).tint(readingAccent)
    }
    private var contents: some View {
        ScrollViewReader { proxy in
            List {
                if reader.chapters.isEmpty { Text("本书未提供目录").foregroundStyle(.secondary).listRowSeparator(.hidden) }
                ForEach(reader.chapters) { chapter in
                    Button { navigate(chapter.href) } label: {
                        HStack(spacing:12) {
                            VStack(alignment:.leading,spacing:5) {
                                Text(chapter.title).font(.body.weight(chapter.id == currentChapter ? .semibold : .regular)).foregroundStyle(.primary)
                                if chapter.id == currentChapter { Text("正在阅读").font(.caption).foregroundStyle(readingAccent) }
                            }
                            Spacer(minLength:6)
                            if chapter.id == currentChapter { Image(systemName:"text.book.closed.fill").font(.subheadline).foregroundStyle(readingAccent) }
                        }.padding(.leading,CGFloat(min(chapter.depth,3))*14).frame(minHeight:48).contentShape(Rectangle())
                    }.buttonStyle(.plain).id(chapter.id).disabled(reader.loading || reader.busy)
                        .accessibilityAddTraits(chapter.id == currentChapter ? .isSelected : [])
                        .listRowBackground(Color.clear)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).onAppear { if let currentChapter { proxy.scrollTo(currentChapter,anchor:.center) } }
        }
    }
    private var bookmarkList: some View {
        VStack(spacing:0) {
            Button {
                if let bookmark = bookmarks.first(where: { $0.id == reader.position?.locator }) { remove(bookmark) }
                else { _ = bookmarkAction { reader.toggleBookmark() } }
            } label: {
                Label(reader.isBookmarked ? "移除当前位置的书签" : "收藏当前阅读位置",systemImage:reader.isBookmarked ? "bookmark.slash" : "bookmark")
                    .font(.subheadline.weight(.medium)).frame(maxWidth:.infinity,minHeight:48)
            }.disabled(reader.loading || reader.busy || reader.position == nil).padding(.horizontal,16)
            if bookmarks.isEmpty {
                ContentUnavailableView { Label("还没有书签",systemImage:"bookmark") } description: { Text("收藏读到的位置，下次从这里接着读。") }
                    .frame(maxHeight:.infinity)
            } else {
                List(bookmarks) { bookmark in
                    HStack(spacing:8) {
                        Button { navigate(bookmark.id) } label: {
                            HStack(spacing:12) {
                                Image(systemName:"bookmark.fill").font(.subheadline).foregroundStyle(readingAccent)
                                VStack(alignment:.leading,spacing:5) {
                                    Text(bookmark.title).foregroundStyle(.primary).lineLimit(2)
                                    Text("已读 \(Int(bookmark.progress*100))%" + (bookmark.id == reader.position?.locator ? " · 当前位置" : ""))
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth:.infinity,minHeight:56,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(reader.loading || reader.busy)
                        Menu { Button("移除书签",systemImage:"bookmark.slash",role:.destructive) { remove(bookmark) } } label: {
                            Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle())
                        }.accessibilityLabel("管理书签：\(bookmark.title)")
                    }.swipeActions { Button("移除",role:.destructive) { remove(bookmark) } }.listRowBackground(Color.clear)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }
    private func remove(_ bookmark: ReaderBookmark) { if bookmarkAction({ reader.setReaderBookmark(bookmark,present:false) }) { removed = bookmark } }
    private func bookmarkAction(_ action: () -> Bool) -> Bool {
        if action() { failure = nil; return true }
        failure = reader.error ?? "书签未能保存，请重试。"; reader.error = nil; return false
    }
}

@MainActor final class ReaderSearchController: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var waiting = false
    private let reader: ReaderModel
    private var pending: Task<Void,Never>?
    init(reader: ReaderModel) { self.reader = reader }
    private func schedule() {
        pending?.cancel(); reader.search("")
        waiting = !ReaderSearchState.normalized(query).isEmpty
        guard waiting else { return }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.waiting = false; self.reader.search(self.query)
        }
    }
    func submit() { pending?.cancel(); waiting = false; reader.search(query) }
    func stop() { pending?.cancel(); waiting = false; reader.search("") }
}

struct ReaderSearchPanel: View {
    @ObservedObject var reader: ReaderModel
    let navigate: (String) -> Void
    let close: () -> Void
    @StateObject private var search: ReaderSearchController
    @FocusState private var focused: Bool
    @Environment(\.readerGlassPanel) private var glass
    init(reader: ReaderModel,navigate: @escaping (String) -> Void,close: @escaping () -> Void) {
        self.reader = reader; self.navigate = navigate; self.close = close
        _search = StateObject(wrappedValue:ReaderSearchController(reader:reader))
    }
    var body: some View {
        VStack(spacing:0) {
            ReaderPanelHeader(title:"搜索书中内容",close:close)
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("输入词语或句子",text:$search.query).textFieldStyle(.plain).focused($focused)
                    .submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never).onSubmit(search.submit)
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary).frame(width:36,height:44) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }.padding(.leading,14).padding(.trailing,4).frame(minHeight:46)
                .background(Color(uiColor:.tertiarySystemFill),in:RoundedRectangle(cornerRadius:12)).padding(.horizontal,22).padding(.bottom,14)
            results
        }.background(glass ? Color.clear : Color(uiColor:.systemBackground)).tint(readingAccent).task { focused = true }.onDisappear { search.stop() }
    }
    @ViewBuilder private var results: some View {
        if search.waiting || reader.searching {
            VStack(spacing:14) { ProgressView(); Text("正在查找…").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else if reader.searchState == .failed {
            ContentUnavailableView { Label("暂时未能完成搜索",systemImage:"exclamationmark.magnifyingglass") } actions: { Button("重新搜索",action:search.submit) }
        } else if reader.results.isEmpty {
            ContentUnavailableView {
                Label(ReaderSearchState.normalized(search.query).isEmpty ? "在书中找一句话" : "没有找到相关内容",systemImage:"text.magnifyingglass")
            } description: { Text(ReaderSearchState.normalized(search.query).isEmpty ? "输入关键词，结果会自动显示在这里。" : "试试更短的词语，或换一个关键词。") }
        } else {
            VStack(alignment:.leading,spacing:0) {
                Text(reader.results.count >= 80 ? "前 80 条结果 · 可缩小搜索范围" : "找到 \(reader.results.count) 处")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,8)
                List(reader.results) { result in
                    Button { navigate(result.href) } label: {
                        Text(excerpt(result.title)).font(.subheadline).lineSpacing(5).lineLimit(5)
                            .frame(maxWidth:.infinity,minHeight:48,alignment:.leading).padding(.vertical,8).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(reader.loading || reader.busy)
                        .accessibilityIdentifier("reader-search-result").listRowBackground(Color.clear)
                }.listStyle(.plain).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
            }
        }
    }
    private func excerpt(_ value: String) -> AttributedString {
        var text = AttributedString(value); text.foregroundColor = .primary
        let keyword = ReaderSearchState.normalized(search.query)
        guard !keyword.isEmpty else { return text }
        var start = value.startIndex
        while start < value.endIndex, let range = value.range(of:keyword,options:.caseInsensitive,range:start..<value.endIndex) {
            if let a = AttributedString.Index(range.lowerBound,within:text), let b = AttributedString.Index(range.upperBound,within:text) {
                text[a..<b].foregroundColor = readingAccent; text[a..<b].font = .subheadline.bold()
            }
            start = range.upperBound
        }
        return text
    }
}

extension ReaderModel {
    /// Reset typography without moving the reader between scrolling and pages.
    func resetReaderTypography() {
        let defaults = ReaderAppearance()
        appearance.font = defaults.font; appearance.fontSize = defaults.fontSize
        appearance.lineHeight = defaults.lineHeight; appearance.margin = defaults.margin; appearance.sideInset = defaults.sideInset
    }
}
