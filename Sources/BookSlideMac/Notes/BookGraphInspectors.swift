import SwiftUI
#if os(iOS)
import UIKit
#endif
#if canImport(BookSlideCore)
import BookSlideCore
#endif

struct BookGraphSource: View {
    @ObservedObject var reader: ReaderModel
    let locator: String
    let href: String
    let palette: BookGraphPalette
    @State private var expanded = false
    @State private var text = ""
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Button { expanded.toggle() } label: { Label(expanded ? "收起原文" : "在此展开原文",systemImage:expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(.plain).foregroundStyle(palette.accent).disabled(locator.isEmpty && href.isEmpty)
            Button {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom != .pad { reader.showNoteGraph = false }
                #else
                reader.showNoteGraph = false
                #endif
                reader.go(locator.isEmpty ? href : locator)
            } label: { Label("在正文中打开",systemImage:"book") }
                .buttonStyle(.plain).foregroundStyle(palette.accent).disabled(reader.loading || reader.busy || (locator.isEmpty && href.isEmpty))
            if expanded {
                if loading { ProgressView("正在读取原文…").font(.caption) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                if !text.isEmpty {
                    ScrollView { Text(text).font(.system(size:16,design:.serif)).lineSpacing(7).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                        .frame(maxHeight:260).padding(14).background(palette.background,in:RoundedRectangle(cornerRadius:9))
                }
            }
        }.font(.callout)
        .task(id:expanded) {
            guard expanded, text.isEmpty else { return }
            loading = true; failure = nil
            do {
                let value = try await reader.graphSource(locator:locator,href:href)
                if !Task.isCancelled { text = value; if value.isEmpty { failure = "这一处暂时没有可显示的正文。" } }
            } catch { if !Task.isCancelled { failure = "原文暂时未能展开，笔记内容仍然保留。可以收起后重试。" } }
            loading = false
        }
    }
}

/// Every visible node uses the same directed connection editor. Choosing a
/// target only edits the local draft; the explicit action commits one edge.
struct ReadingNodeLinks: View {
    @ObservedObject var reader: ReaderModel
    let palette: BookGraphPalette
    private let bookID: UUID?
    private let close: (() -> Void)?
    private let connected: ((ReadingEdge.ID) -> Void)?
    @State private var source: ReadingNodeID?
    @State private var target: ReadingNodeID?
    @State private var query = ""
    @State private var label = "关联"
    @State private var choosingSource: Bool
    @State private var choosingEndpoint = true
    @State private var failure: String?
    @FocusState private var searching: Bool
    @FocusState private var naming: Bool
    @Environment(\.dismiss) private var dismiss
    init(reader: ReaderModel,source: ReadingNodeID? = nil,palette: BookGraphPalette,close: (() -> Void)? = nil,connected: ((ReadingEdge.ID) -> Void)? = nil) {
        self.reader = reader; self.palette = palette; self.close = close; self.connected = connected; bookID = reader.currentID
        _source = State(initialValue:source); _choosingSource = State(initialValue:source == nil)
    }
    private var graph: ReadingGraph { reader.books.first(where:{ $0.id == bookID })?.graph ?? ReadingGraph() }
    private var matches: [ReadingNode] {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        let other = choosingSource ? target : source
        return Array(reader.bookNotesIndex.searchNodes(query,through:reader.noteVisibilityProgress).filter {
            $0.id != other && [.entity,.note,.discussion,.ink].contains($0.id.kind)
        }.prefix(12))
    }
    private var valid: Bool {
        guard let source, let target, source != target, reader.currentID == bookID,
              let a = graph.node(source), a.deletedAt == nil, let b = graph.node(target), b.deletedAt == nil else { return false }
        let name = label.trimmingCharacters(in:.whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 160
    }
    private var existingConnection: ReadingEdge? {
        guard let source, let target else { return nil }
        let name = label.trimmingCharacters(in:.whitespacesAndNewlines)
        return graph.searchEdges("").first { $0.id.source == source && $0.id.target == target && $0.label == name }
    }
    private func type(_ id: ReadingNodeID) -> String {
        if case .entity(let entity) = graph.node(id)?.content { return entity.kind.title }
        switch id.kind {
        case .note: return "笔记"
        case .discussion: return "AI 对话"
        case .ink: return "手写笔记"
        default: return "内容"
        }
    }
    private func endpoint(_ id: ReadingNodeID?,origin: Bool) -> some View {
        ReadingEndpointCard(role:origin ? "起点" : "终点",title:id.flatMap { graph.title(for:$0) } ?? (origin ? "选择起点" : "选择终点"),selected:choosingEndpoint && choosingSource == origin) {
            choosingSource = origin; choosingEndpoint = true; query = ""; failure = nil; searching = true
        }.accessibilityLabel(origin ? "选择连接起点" : "选择连接终点")
            .accessibilityValue(id.flatMap { graph.title(for:$0) } ?? "未选择")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            ReadingEditorHeader(title:"添加连接",symbol:"link",back:close == nil ? nil : cancel,backLabel:"取消添加连接") {
                if close == nil { ReadingToolButton(symbol:"xmark",label:"取消添加连接",action:cancel) }
            }
            HStack(spacing:8) {
                endpoint(source,origin:true)
                Button {
                    let previous = source; source = target; target = previous
                    choosingEndpoint = false; query = ""; searching = false
                } label: { Image(systemName:"arrow.right").frame(width:32,height:44) }
                    .buttonStyle(.plain).disabled(source == nil || target == nil).accessibilityLabel("交换连接方向")
                endpoint(target,origin:false)
            }
            if choosingEndpoint {
                TextField(choosingSource ? "搜索起点" : "搜索终点",text:$query)
                    .modifier(ReadingFieldSurface()).accessibilityLabel("搜索连接节点").focused($searching)
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        ForEach(matches) { node in
                            Button { choose(node.id) } label: {
                                HStack(alignment:.top,spacing:12) {
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(type(node.id)).font(.caption2).foregroundStyle(.secondary)
                                        Text(graph.title(for:node.id) ?? node.title).font(.callout.weight(.medium)).lineLimit(2)
                                        if !node.text.isEmpty { Text(node.text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                    Spacer(minLength:0)
                                    Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("选择\(type(node.id))：\(graph.title(for:node.id) ?? node.title)")
                                .accessibilityIdentifier("reading-connection-target-\(node.id.kind.rawValue)-\(node.id.owner)-\(node.id.local ?? "")")
                            Divider()
                        }
                        if matches.isEmpty {
                            Text(query.isEmpty ? "搜索要连接的内容。" : "没有找到匹配的内容。")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical,8)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            } else {
                ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    Text("关系名称").font(.subheadline.weight(.medium))
                    TextField("例如：师父、回应、引用",text:$label).modifier(ReadingFieldSurface())
                        .accessibilityLabel("连接关系名称").focused($naming)
                    HStack(spacing:10) {
                        ForEach(["关联","回应","引用"],id:\.self) { name in
                            Button(name) { label = name }.font(.caption).buttonStyle(.bordered)
                        }
                    }
                    if existingConnection != nil { Text("已有相同连接，可以直接查看。").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if !choosingEndpoint {
                ReadingCreationFooter(hint:"按箭头方向连接，名称可以自由填写。") {
                    Button(existingConnection == nil ? "添加连接" : "查看连接",action:connect)
                        .disabled(!valid).accessibilityIdentifier("reading-add-connection")
                }
            }
        }.padding(.horizontal,close == nil ? ReadingInterface.sheetInset : ReadingInterface.inset)
            .padding(.top,close == nil ? 24 : 8).padding(.bottom,close == nil ? 24 : 12).frame(maxWidth:.infinity,maxHeight:.infinity)
            .modifier(ReadingCreationSurface(floating:close == nil,palette:palette)).foregroundStyle(palette.ink).tint(palette.accent)
        #if os(iOS)
        .presentationDetents([.height(420),.large]).presentationDragIndicator(.visible)
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillHideNotification)) { _ in
            searching = false; naming = false
        }
        #else
        .frame(width:420,height:420)
        #endif
    }
    private func choose(_ id: ReadingNodeID) {
        if choosingSource {
            source = id; if target == id { target = nil }
            choosingSource = false; choosingEndpoint = target == nil
        } else { target = id; choosingEndpoint = false }
        query = ""; failure = nil; searching = choosingEndpoint
    }
    private func cancel() { if let close { close() } else { dismiss() } }
    private func connect() {
        guard valid, let source, let target, let bookID,
              let edge = reader.connectReadingNodes(from:source,to:target,label:label,bookID:bookID) else {
            failure = reader.error ?? "请选择起点、终点和关系名称。"; return
        }
        if let connected {
            // The presenting view reveals the edge from its sheet's onDismiss,
            // after UIKit has completed the dismissal animation.
            connected(edge); dismiss()
        } else { reader.revealReadingConnection(edge,bookID:bookID) }
    }
}

struct ReadingConnectionInspector: View {
    @ObservedObject var reader: ReaderModel
    let original: ReadingEdge
    let palette: BookGraphPalette
    let openEndpoint: ((ReadingNodeID) -> Void)?
    let close: () -> Void
    private let bookID: UUID?
    @State private var label: String
    @State private var baseline: String
    @State private var failure: String?
    @State private var finished = false
    init(reader: ReaderModel,edge: ReadingEdge,palette: BookGraphPalette,openEndpoint: ((ReadingNodeID) -> Void)? = nil,close: @escaping () -> Void) {
        self.openEndpoint = openEndpoint
        self.reader = reader; original = edge; self.palette = palette; self.close = close; bookID = reader.currentID
        _label = State(initialValue:edge.label); _baseline = State(initialValue:edge.label)
    }
    var body: some View {
        VStack(spacing:0) {
            ReadingEditorHeader(title:"连接",symbol:"link",status:"自动保存",back:close,backLabel:openEndpoint == nil ? "返回图中" : "返回连接列表") {
                Menu {
                    Button("解除连接",role:.destructive) {
                        if reader.performReadingMutation(.disconnect(original.id),bookID:bookID) { finished = true; close() } else { failure = reader.error }
                    }
                } label: { Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("连接更多操作")
            }.padding(.horizontal,openEndpoint == nil ? ReadingInterface.inset : 0).padding(.vertical,4)
            ScrollView {
            VStack(alignment:.leading,spacing:18) {
                TextField("连接名称",text:$label).modifier(ReadingFieldSurface()).accessibilityLabel("节点连接名称")
                HStack(spacing:8) {
                    ReadingEndpointCard(role:"起点",title:reader.bookNotesIndex.graph.title(for:original.id.source) ?? "起点") { selectEndpoint(original.id.source) }
                    Image(systemName:"arrow.right").font(.caption).foregroundStyle(.secondary)
                    ReadingEndpointCard(role:"终点",title:reader.bookNotesIndex.graph.title(for:original.id.target) ?? "终点") { selectEndpoint(original.id.target) }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding(openEndpoint == nil ? ReadingInterface.inset : 4).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.background(palette.paper).tint(palette.accent)
        .task(id:label) {
            do { try await Task.sleep(for:.milliseconds(650)) } catch { return }
            if !Task.isCancelled { persist() }
        }
        .onDisappear { if !finished { persist() } }
    }
    private func selectEndpoint(_ id: ReadingNodeID) {
        if let openEndpoint { openEndpoint(id) } else { reader.selectReadingItem(.node(id)) }
    }
    private func persist() {
        guard !finished, let bookID, label != baseline, !label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        guard reader.books.first(where:{ $0.id == bookID })?.graph.edges.contains(where:{ $0.id == original.id && $0.deletedAt == nil }) == true else { return }
        var edge = original; edge.label = label
        if reader.performReadingMutation(.connect(edge),bookID:bookID) { baseline = label; failure = nil } else { failure = reader.error }
    }
}

struct BookGraphNoteInspector: View {
    @ObservedObject var reader: ReaderModel
    let original: ReaderAnnotation
    let palette: BookGraphPalette
    let includeFuture: Bool
    let select: (BookGraphSelection) -> Void
    var connect: ((ReadingNodeID) -> Void)?
    var compact = false
    var nodeMode = false
    var toggleExpansion: (() -> Void)?
    var initialFocusAllowed: Bool
    private let bookID: UUID?
    @State private var item: ReaderAnnotation
    @State private var baseline: ReaderAnnotation
    @State private var finished = false
    @State private var recovered: Bool
    @State private var status: String?
    @State private var failure: String?
    @State private var organizing = false
    @State private var createdConnection: ReadingEdge.ID?
    @State private var discussing = false
    @State private var discussionRunning = false
    @State private var initialFocusRequested = false
    @FocusState private var focused: Bool
    @Environment(\.readingCompanionChrome) private var companionChrome
    @Environment(\.scenePhase) private var scenePhase
    init(reader: ReaderModel,original: ReaderAnnotation,palette: BookGraphPalette,includeFuture: Bool,compact: Bool = false,nodeMode: Bool = false,initialDiscussion: Bool? = nil,toggleExpansion: (() -> Void)? = nil,initialFocusAllowed: Bool = true,connect: ((ReadingNodeID) -> Void)? = nil,select: @escaping (BookGraphSelection) -> Void) {
        self.reader = reader; self.original = original; self.palette = palette; self.includeFuture = includeFuture; self.select = select; bookID = reader.currentID
        self.compact = compact; self.toggleExpansion = toggleExpansion
        self.nodeMode = nodeMode
        self.initialFocusAllowed = initialFocusAllowed
        self.connect = connect
        let recovered = reader.textNoteDrafts.first { $0.id == original.id }?.annotation
        let value = reader.currentID.map { reader.noteForEditing(original,bookID:$0) } ?? original
        _item = State(initialValue:value); _baseline = State(initialValue:value)
        _recovered = State(initialValue:recovered != nil)
        _discussing = State(initialValue:initialDiscussion ?? (reader.discussionNoteID == original.id))
    }
    private var locator: String { item.readingLocator }
    var body: some View {
        VStack(spacing:0) {
            if !nodeMode { VStack(alignment:.leading,spacing:10) {
                ReadingEditorHeader(title:discussing ? "AI 对话" : nodeMode ? "节点" : "笔记",symbol:discussing ? "bubble.left.and.bubble.right" : "note.text",status:status ?? (recovered ? "已恢复草稿" : "自动保存"),statusID:"note-save-status",
                    back:toggleExpansion == nil ? nil : {
                        if persist() { select(.chapter(reader.bookNotesIndex.notes.first(where:{ $0.id == item.id })?.chapterID ?? reader.currentNoteSectionID)) }
                    },backLabel:"返回本章脉络",discussionMode:toggleExpansion == nil ? nil : $discussing) {
                    if toggleExpansion == nil {
                        ReadingToolButton(symbol:"link",label:"添加连接") {
                            if persist() {
                                if let connect { connect(.init(discussing ? .discussion : .note,item.id)) } else { organizing = true }
                            }
                        }.disabled(discussionRunning)
                    }
                    Menu {
                        if let toggleExpansion {
                            Button("添加连接",systemImage:"link") { if persist() { connect?(.init(discussing ? .discussion : .note,item.id)) } }
                                .disabled(discussionRunning)
                            if !discussing { Button(compact ? "展开笔记编辑" : "收起笔记编辑",action:toggleExpansion) }
                        }
                        Button("定位原文",systemImage:"book") { reader.go(locator) }
                            .disabled(reader.busy || reader.loading || locator.isEmpty)
                        if reader.currentAnnotations.contains(where:{ $0.id == item.id }) {
                            Divider()
                            Button("移到最近删除",role:.destructive) {
                                if let bookID, reader.removeAnnotation(item.id,bookID:bookID) { finished = true }
                                else { failure = reader.error }
                            }.disabled(discussionRunning)
                        }
                    } label: { Image(systemName:"ellipsis").frame(width:44,height:44) }
                        .buttonStyle(.plain).accessibilityLabel(nodeMode ? "节点更多操作" : "笔记更多操作")
                }
                if companionChrome != nil {
                    Text(status ?? (recovered ? "已恢复草稿" : "自动保存"))
                        .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("note-save-status")
                }
                if toggleExpansion == nil {
                    Picker("笔记与讨论",selection:$discussing) {
                        Text(nodeMode ? "节点内容" : "我的笔记").tag(false)
                        Text("AI 对话").tag(true)
                    }.pickerStyle(.segmented)
                }
            }.padding(.horizontal,20).padding(.top,8).padding(.bottom,compact ? 6 : 12) }
            if discussing, let bookID {
                ReaderDiscussionPanel(reader:reader,item:$item,bookID:bookID,palette:palette,runningChanged:{ discussionRunning = $0 })
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:compact ? 12 : 20) {
                        noteEditor
                        if !item.quote.isEmpty {
                            ReadingSourceCard(chapter:compact ? nil : item.chapter,text:item.quote,lineLimit:nil)
                        }
                        if !nodeMode {
                            ReaderNoteConnections(reader:reader,item:$item,palette:palette,through:reader.noteVisibilityProgress)
                            Button { if persist() { select(.newEvent) } } label: { Label("添加事件：连接两个节点",systemImage:"arrow.triangle.branch") }
                                .buttonStyle(.bordered).accessibilityIdentifier("note-add-event")
                        }
                    }.padding(.horizontal,nodeMode ? 2 : 20).padding(.bottom,compact ? 8 : 20)
                        .modifier(GraphCardContentSize(enabled:nodeMode))
                }
            }
            if let failure {
                HStack {
                    Text(failure).font(.caption).foregroundStyle(.red)
                    Spacer(minLength:8)
                    Button("重试") { persist() }.font(.caption).frame(minWidth:44,minHeight:44)
                        .accessibilityLabel("重试自动保存")
                }.padding(.horizontal,20)
            }
        }.background(nodeMode ? Color.clear : palette.paper).tint(palette.accent)
        #if os(iOS)
        .sheet(isPresented:$organizing,onDismiss:finishConnection) { noteDetails }
        #else
        .popover(isPresented:$organizing) { noteDetails }
        .onChange(of:organizing) { shown in if !shown { finishConnection() } }
        #endif
        .task(id:initialFocusAllowed) {
            guard !initialFocusRequested, initialFocusAllowed else { return }
            initialFocusRequested = true
            if item.canvasText.isEmpty && !discussing && !nodeMode {
                await Task.yield()
                guard !Task.isCancelled, reader.currentID == bookID, initialFocusAllowed else { return }
                focused = true
            }
            if discussing { reader.discussionNoteID = item.id }
        }
        .onChange(of:reader.discussionNoteID) { id in
            if id == item.id { discussing = true; focused = false }
            else if id == nil { discussing = false }
        }
        .onChange(of:discussing) { value in
            persist()
            focused = false
            if value { reader.discussionNoteID = item.id }
            else if reader.discussionNoteID == item.id { reader.discussionNoteID = nil }
        }
        .preference(key:CanvasEditorSave.self,value:nodeMode ? persist : nil)
        .onChange(of:item) { _ in finished = false; status = "正在保存…" }
        .task(id:item) {
            do { try await Task.sleep(for:.milliseconds(650)) } catch { return }
            if !Task.isCancelled { persist() }
        }
        .onChange(of:scenePhase) { phase in if phase != .active { persist() } }
        .onDisappear { persist() }
    }
    @ViewBuilder private var noteEditor: some View {
        let text = Binding(get:{ item.canvasText },set:{ value in
            item.note = value
            if value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { item.title = nil }
        })
        if nodeMode {
            BookGraphNodeTextEditor(text:text,palette:palette,label:"节点内容").focused($focused)
        } else {
            ZStack(alignment:.topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("写下此刻的想法…").font(BookGraphNodeTextEditor.font).foregroundStyle(palette.ink.opacity(0.38))
                        .padding(.horizontal,5).padding(.vertical,8).allowsHitTesting(false)
                }
                TextEditor(text:text).font(BookGraphNodeTextEditor.font).lineSpacing(5).scrollContentBackground(.hidden)
                    .focused($focused).accessibilityLabel("笔记内容")
            }.frame(height:compact ? 120 : 180)
        }
    }
    private var noteDetails: some View {
        ReadingNodeLinks(reader:reader,source:discussing ? .init(.discussion,item.id) : .init(.note,item.id),palette:palette,connected:{ createdConnection = $0 })
    }
    private func finishConnection() {
        guard let edge = createdConnection, let bookID else { return }
        createdConnection = nil
        reader.revealReadingConnection(edge,bookID:bookID)
    }
    @discardableResult private func persist() -> Bool {
        guard let bookID else { return false }
        // State may already contain the last keystroke while onChange has not
        // reset finished yet. Closing must compare content, not that callback.
        guard !finished || item != baseline || recovered else { return true }
        guard !reader.isNoteRemoved(item.id,bookID:bookID) else { return true }
        if item == baseline && !recovered && reader.books.first(where:{ $0.id == bookID })?.annotations?.contains(where:{ $0.id == item.id }) == true {
            status = "自动保存"; return true
        }
        if reader.autosaveGraphAnnotation(item,bookID:bookID,relation:item.graphRelationDraft) {
            baseline = item; finished = true; recovered = false; failure = nil; status = "已自动保存"; return true
        }
        let message = reader.error ?? "笔记暂时未能保存。"
        do {
            try reader.keepTextDraft(item,bookID:bookID); status = "已保留草稿"
            failure = "自动保存未完成，内容已保留为本机草稿。\(message)"; return true
        } catch { failure = "自动保存失败，请保留当前页面并重试：\(error.localizedDescription)"; return false }
    }
}

/// Both note entry points edit the same associations and relation draft.
struct ReaderNoteConnections: View {
    @ObservedObject var reader: ReaderModel
    @Binding var item: ReaderAnnotation
    let palette: BookGraphPalette
    let through: Double
    @State private var addingEntity = false
    private var linked: [BookEntity] {
        (item.entityIDs ?? []).compactMap { id in reader.bookNotesIndex.entities.first { $0.id == id } }
    }
    private var suggested: [BookEntity] {
        Array(reader.bookNotesIndex.suggestedEntities(for:item,through:through).prefix(6))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("关联节点").font(.headline)
                Spacer()
                Button { addingEntity.toggle() } label: { Label(addingEntity ? "收起" : "新建或选择",systemImage:"plus") }.buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            if !linked.isEmpty {
                GraphWrappingLayout {
                    ForEach(linked) { entity in
                        Button {
                            item.entityIDs?.removeAll { $0 == entity.id }
                            if item.graphRelationDraft?.sourceID == entity.id || item.graphRelationDraft?.targetID == entity.id {
                                item.graphRelationDraft = nil
                            }
                        } label: {
                            HStack(spacing:6) { Image(systemName:entity.kind.symbol); Text(entity.name); Image(systemName:"xmark").font(.caption2) }
                                .font(.callout).padding(.horizontal,10).padding(.vertical,7)
                        }.buttonStyle(.plain).background(palette.background,in:Capsule())
                            .accessibilityLabel("取消关联\(entity.name)")
                    }
                }
            }
            if addingEntity {
                BookGraphEntityPicker(reader:reader,ids:Binding(get:{item.entityIDs ?? []},set:{item.entityIDs = $0}),palette:palette)
            }
            if linked.count >= 2 {
                Toggle("补充一条关系",isOn:Binding(get:{item.graphRelationDraft != nil},set:{ enabled in
                    item.graphRelationDraft = enabled ? makeRelation() : nil
                })).font(.callout)
                if item.graphRelationDraft != nil { relationEditor }
            }

            if linked.isEmpty {
                Text("点「新建或选择」添加人物、地点等节点，与这条笔记相连。").font(.caption).foregroundStyle(.secondary)
            }
            if !suggested.isEmpty {
                Text("这段内容提到了").font(.caption).foregroundStyle(.secondary)
                GraphWrappingLayout {
                    ForEach(suggested) { entity in
                        Button {
                            item.entityIDs = (item.entityIDs ?? []) + [entity.id]
                        } label: { Label(entity.name,systemImage:"plus.circle").font(.callout).padding(7) }
                            .buttonStyle(.plain).foregroundStyle(palette.accent)
                            .accessibilityLabel("关联\(entity.name)")
                    }
                }
            }
        }.font(.callout).accessibilityIdentifier("note-connections")
        .onChange(of:item.entityIDs) { ids in
            if item.quote.isEmpty && item.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && (item.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
               let id = ids?.first, let entity = reader.bookNotesIndex.entities.first(where:{ $0.id == id }) {
                item.title = entity.name
            }
            if let relation = item.graphRelationDraft, !Set(ids ?? []).isSuperset(of:[relation.sourceID,relation.targetID]) {
                item.graphRelationDraft = nil
            }
        }
    }
    private var relationEditor: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:5) {
                Menu {
                    ForEach(linked) { entity in Button(entity.name) { changeRelation { $0.sourceID = entity.id } } }
                } label: { Text(linked.first(where: { $0.id == item.graphRelationDraft?.sourceID })?.name ?? linked[0].name).lineLimit(1) }
                Image(systemName:"arrow.right").font(.caption2).foregroundStyle(.secondary)
                TextField("如：师父",text:Binding(get:{item.graphRelationDraft?.label ?? ""},set:{ value in changeRelation { $0.label = value } }))
                    .textFieldStyle(.plain).frame(minWidth:48,maxWidth:85).accessibilityLabel("关系名称")
                Image(systemName:"arrow.right").font(.caption2).foregroundStyle(.secondary)
                Menu {
                    ForEach(linked) { entity in Button(entity.name) { changeRelation { $0.targetID = entity.id } } }
                } label: { Text(linked.first(where: { $0.id == item.graphRelationDraft?.targetID })?.name ?? linked[1].name).lineLimit(1) }
            }.font(.callout).padding(12).background(palette.background,in:RoundedRectangle(cornerRadius:9))
            Toggle("这是我的推测",isOn:Binding(get:{item.graphRelationDraft?.conjecture ?? false},set:{ value in changeRelation { $0.conjecture = value } })).font(.caption)
        }
    }
    private func makeRelation() -> BookRelation? {
        guard linked.count >= 2 else { return nil }
        return BookRelation(sourceID:linked[0].id,targetID:linked[1].id,label:"",evidenceIDs:[item.id],conjecture:item.quote.isEmpty)
    }
    private func changeRelation(_ change: (inout BookRelation) -> Void) {
        guard var value = item.graphRelationDraft ?? makeRelation() else { return }
        change(&value); item.graphRelationDraft = value
    }
}

struct ReaderRelatedNotes: View {
    @ObservedObject var reader: ReaderModel
    let item: ReaderAnnotation
    let through: Double
    let open: (BookGraphNote) -> Void
    private var notes: [BookGraphNote] { Array(reader.bookNotesIndex.relatedNotes(for:item,through:through).prefix(4)) }
    var body: some View {
        if !notes.isEmpty {
            VStack(alignment:.leading,spacing:12) {
                Label("已有笔记",systemImage:"books.vertical").font(.headline)
                Text("同一事物或章节的记录，供你对照。").font(.caption).foregroundStyle(.secondary)
                ForEach(notes) { note in
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:10) {
                            if !note.quote.isEmpty { Text(note.quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                            if !note.text.isEmpty { Text(note.text).font(.callout).textSelection(.enabled) }
                            if note.ink, let ink = reader.currentPageNotes.first(where:{ $0.id.uuidString == note.id }), let image = reader.pageNoteImage(ink) {
                                #if os(macOS)
                                Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:180)
                                #else
                                Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:180)
                                #endif
                            }
                            Button("在脉络中查看") { open(note) }.buttonStyle(.borderless)
                        }.padding(.vertical,8)
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text(note.title).font(.callout).lineLimit(2)
                            Text(note.chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }.accessibilityIdentifier("note-related-notes")
        }
    }
}

struct BookGraphEntityPicker: View {
    @ObservedObject var reader: ReaderModel
    @Binding var ids: [UUID]
    let palette: BookGraphPalette
    var inline = false
    @State private var name = ""
    @State private var kind = BookEntityKind.person
    @State private var failure: String?
    @FocusState private var searching: Bool
    private var query: String { name.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var matches: [BookEntity] {
        let entities = reader.bookNotesIndex.entities
        if query.isEmpty {
            return inline ? entities.filter { ids.contains($0.id) } : Array(entities.prefix(6))
        }
        return Array(entities.lazy.filter { $0.matches(query) }.prefix(6))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:inline ? 4 : 12) {
            if inline {
                HStack(spacing:8) {
                    Image(systemName:"magnifyingglass").font(.callout).foregroundStyle(palette.canvasAccent)
                        .accessibilityHidden(true)
                    TextField("搜索或新建事物",text:$name).textFieldStyle(.plain).focused($searching)
                        .accessibilityLabel("事物名称")
                }.padding(.horizontal,10).frame(minHeight:40)
                    .background(palette.canvasAccent.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
            } else {
                TextField("输入名称，查找或新建",text:$name).textFieldStyle(.roundedBorder).accessibilityLabel("事物名称")
            }
            ForEach(matches) { entity in
                let selected = ids.contains(entity.id)
                Button {
                    if selected { ids.removeAll { $0 == entity.id } }
                    else { ids.append(entity.id) }
                    if inline { name = ""; searching = false }
                } label: {
                    HStack(spacing:8) {
                        Label(entity.name,systemImage:entity.kind.symbol).lineLimit(1)
                        Spacer(minLength:0)
                        if selected { Image(systemName:"checkmark").foregroundStyle(inline ? palette.canvasAccent : palette.ink).accessibilityHidden(true) }
                    }.font(.callout).frame(minHeight:inline ? 44 : 0)
                        .padding(.vertical,inline ? 0 : 6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
            if !query.isEmpty && (!inline || !matches.contains { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }) {
                HStack {
                    Picker("类型",selection:$kind) { ForEach(BookEntityKind.allCases,id:\.self) { Text($0.title).tag($0) } }.labelsHidden().frame(maxWidth:120)
                    Button("创建并关联") {
                        if let id = reader.saveKnowledgeEntity(BookEntity(name:query,kind:kind)) {
                            if !ids.contains(id) { ids.append(id) }; name = ""; failure = nil; searching = false
                        } else { failure = reader.error }
                    }.buttonStyle(.borderless).foregroundStyle(inline ? palette.canvasAccent : palette.accent)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.padding(inline ? 0 : 14)
            .background(inline ? Color.clear : palette.background,in:RoundedRectangle(cornerRadius:9))
    }
}

struct BookGraphEntityInspector: View {
    @ObservedObject var reader: ReaderModel
    let original: BookEntity
    let palette: BookGraphPalette
    let includeFuture: Bool
    let nodeMode: Bool
    let select: (BookGraphSelection) -> Void
    var connect: ((ReadingNodeID) -> Void)?
    @State private var entity: BookEntity
    @State private var aliases: String
    @State private var status: String?
    @State private var failure: String?
    @State private var baseline: BookEntity
    @State private var finished = false
    @State private var linking = false
    @State private var createdConnection: ReadingEdge.ID?
    @Environment(\.scenePhase) private var scenePhase
    private let bookID: UUID?
    init(reader: ReaderModel,original: BookEntity,palette: BookGraphPalette,includeFuture: Bool,nodeMode: Bool = false,connect: ((ReadingNodeID) -> Void)? = nil,select: @escaping (BookGraphSelection) -> Void) {
        self.reader = reader; self.original = original; self.palette = palette; self.includeFuture = includeFuture; self.select = select; bookID = reader.currentID
        self.nodeMode = nodeMode
        self.connect = connect
        var value = original
        if nodeMode, value.note == nil, let graph = reader.currentBook?.graph {
            let source = ReadingNodeID(.entity,original.id.uuidString)
            if let owner = graph.edges.first(where:{ $0.id.source == source && $0.id.kind == .association && $0.label == "AI 对话" && $0.deletedAt == nil && $0.id.target.kind == .discussion })?.id.target.owner {
                value.note = graph.annotations.first(where:{ $0.id == owner })?.note
            }
        }
        let initial = value
        if let bookID = reader.currentID, let draft = try? reader.readingNodeDraftStore.load(bookID:bookID,id:.init(.entity,original.id.uuidString)), case .entity(let recovered) = draft.node.content { value = recovered }
        _entity = State(initialValue:value); _aliases = State(initialValue:value.aliases.joined(separator:"、")); _baseline = State(initialValue:initial)
    }
    private var edited: BookEntity {
        var value = entity; value.aliases = aliases.components(separatedBy:CharacterSet(charactersIn:"、,，;；\n")).filter { !$0.isEmpty }; return value
    }
    var body: some View {
        VStack(spacing:0) {
            if !nodeMode { ReadingEditorHeader(title:"节点",symbol:entity.kind.symbol,status:status ?? "自动保存",statusID:"node-save-status",back:{ if persist() { select(.entities) } }) {
                ReadingToolButton(symbol:"sparkles",label:"AI 对话") {
                    if persist(), let target = reader.beginReadingNodeDiscussion(.init(.entity,entity.id.uuidString)) {
                        select(.discussion(target.owner))
                    }
                }
                ReadingToolButton(symbol:"link",label:"添加连接") {
                    if persist() {
                        if let connect { connect(.init(.entity,entity.id.uuidString)) } else { linking = true }
                    }
                }
                Menu {
                    Button("移除节点",role:.destructive) {
                        if reader.setKnowledgeEntityDeleted(entity.id,deleted:true) { finished = true; select(.entities) }
                        else { failure = reader.error }
                    }
                } label: { Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("节点更多操作")
            }.padding(.horizontal,ReadingInterface.inset).padding(.vertical,8) }
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                if nodeMode {
                    BookGraphNodeTextEditor(text:Binding(get:{ entity.note ?? "" },set:{ entity.note = $0 }),palette:palette,label:"节点内容")
                } else {
                    HStack(spacing:12) {
                        TextField("名称",text:$entity.name).modifier(ReadingFieldSurface()).accessibilityLabel("节点名称")
                        Picker("类型",selection:$entity.kind) { ForEach(BookEntityKind.allCases,id:\.self) { Text($0.title).tag($0) } }
                            .pickerStyle(.menu).frame(minHeight:44).accessibilityLabel("节点类型")
                    }
                    TextField("别名，用顿号分隔（可选）",text:$aliases).modifier(ReadingFieldSurface()).accessibilityLabel("节点别名")
                }
                if let failure {
                    HStack {
                        Text(failure).font(.caption).foregroundStyle(.red)
                        Button("重试") { persist() }.frame(minWidth:44,minHeight:44).accessibilityLabel("重试自动保存节点")
                    }
                }
                if !nodeMode {
                    ForEach(reader.bookNotesIndex.graph.searchEdges("").filter { $0.id.source == .init(.entity,entity.id.uuidString) || $0.id.target == .init(.entity,entity.id.uuidString) }) { edge in
                        Button { reader.selectReadingItem(.edge(edge.id)) } label: {
                            HStack {
                                Text("\(reader.bookNotesIndex.graph.title(for:edge.id.source) ?? "") → \(edge.label) → \(reader.bookNotesIndex.graph.title(for:edge.id.target) ?? "")").font(.callout).lineLimit(2)
                                Spacer(minLength:0)
                                Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(palette.accent)
                    }
                    Divider()
                    Text("原文与相关笔记").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(reader.bookNotesIndex.visibleNotes(through:reader.noteVisibilityProgress,includeFuture:includeFuture).filter { $0.entityIDs.contains(entity.id) }) { note in
                        Button { select(.note(note.id)) } label: {
                            VStack(alignment:.leading,spacing:8) { Text(note.title).font(.callout.weight(.medium)); Text(note.chapter).font(.caption).foregroundStyle(.secondary); if !note.quote.isEmpty { Text(note.quote).font(.callout).lineLimit(3) }; Divider() }
                                .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(nodeMode ? 2 : ReadingInterface.inset).frame(maxWidth:.infinity,alignment:.leading)
                .modifier(GraphCardContentSize(enabled:nodeMode))
        }
        }.background(nodeMode ? Color.clear : palette.paper).tint(palette.accent)
        #if os(iOS)
        .sheet(isPresented:$linking,onDismiss:finishConnection) {
            ReadingNodeLinks(reader:reader,source:.init(.entity,entity.id.uuidString),palette:palette,connected:{ createdConnection = $0 })
        }
        #else
        .popover(isPresented:$linking) {
            ReadingNodeLinks(reader:reader,source:.init(.entity,entity.id.uuidString),palette:palette,connected:{ createdConnection = $0 })
        }
        .onChange(of:linking) { shown in if !shown { finishConnection() } }
        #endif
        .preference(key:CanvasEditorSave.self,value:nodeMode ? persist : nil)
        .task(id:edited) {
            guard edited != baseline else { return }
            status = "正在保存…"
            do { try await Task.sleep(for:.milliseconds(650)) } catch { return }
            if !Task.isCancelled { persist() }
        }
        .onChange(of:scenePhase) { phase in if phase != .active { persist() } }
        .onDisappear { if !finished { persist() } }
    }
    private func finishConnection() {
        guard let edge = createdConnection, let bookID else { return }
        createdConnection = nil
        reader.revealReadingConnection(edge,bookID:bookID)
    }
    @discardableResult private func persist() -> Bool {
        guard !finished, let bookID else { return true }
        let value = edited
        guard value != baseline else { return true }
        let id = ReadingNodeID(.entity,value.id.uuidString)
        guard let node = reader.books.first(where:{ $0.id == bookID })?.graph.node(id), node.deletedAt == nil else { finished = true; return true }
        if !value.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, reader.saveKnowledgeEntity(value,bookID:bookID) != nil {
            baseline = value; status = "已自动保存"; failure = nil; return true
        }
        do {
            try reader.keepReadingNodeDraft(.init(id:id,content:.entity(value)),bookID:bookID)
            status = "已保留草稿"
            failure = value.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "补上名称后会自动保存。" : "自动保存暂未完成，修改已保留为本机草稿。"
            return true
        } catch { failure = "修改未能保留，请保留当前页面并重试。"; return false }
    }
}

struct BookGraphRelationInspector: View {
    let index: BookNotesIndex
    let relation: BookRelation
    let palette: BookGraphPalette
    let select: (BookGraphSelection) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Label("关系与依据",systemImage:"point.3.connected.trianglepath.dotted").font(.caption).foregroundStyle(.secondary)
                Text("\(index.entities.first { $0.id == relation.sourceID }?.name ?? "") → \(index.entities.first { $0.id == relation.targetID }?.name ?? "")").font(.system(size:25,weight:.medium,design:.serif))
                Text(relation.label).font(.title3).foregroundStyle(palette.accent)
                if relation.conjecture { Text("我的推测").font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("原文依据与笔记").font(.headline)
                ForEach(index.notes.filter { relation.evidenceIDs.contains($0.id) }) { note in
                    Button { select(.note(note.id)) } label: {
                        VStack(alignment:.leading,spacing:12) {
                            Label(note.chapter,systemImage:"book").font(.caption).foregroundStyle(.secondary)
                            if !note.quote.isEmpty { Text(note.quote).font(.system(size:17,design:.serif)).lineSpacing(4) }
                            Text(note.text.isEmpty ? note.title : note.text).font(.callout).foregroundStyle(.secondary)
                            Label("展开笔记与原文",systemImage:"arrow.right").font(.callout).foregroundStyle(palette.accent)
                            Divider()
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(26).frame(maxWidth:.infinity,alignment:.leading)
        }.background(palette.paper)
    }
}

struct GraphCardContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,nextValue: () -> CGFloat) { value = max(value,nextValue()) }
}

struct GraphCardContentSize: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(key:GraphCardContentHeight.self,value:ceil(geometry.size.height))
                }
            }
        }
    }
}

private struct BookGraphNodeTextEditor: View {
    @Binding var text: String
    let palette: BookGraphPalette
    let label: String
    static let font = Font.body
    private let placeholder = "写下此刻的想法…"

    var body: some View {
        Text(text.isEmpty ? placeholder : text + "\u{200B}")
            .font(Self.font).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
            .padding(.horizontal,5).padding(.vertical,8)
            .frame(maxWidth:.infinity,minHeight:44,alignment:.topLeading)
            .foregroundStyle(text.isEmpty ? palette.ink.opacity(0.38) : Color.clear)
            .accessibilityHidden(true)
            .overlay {
                TextEditor(text:$text).font(Self.font).lineSpacing(5)
                    .scrollDisabled(true).scrollContentBackground(.hidden)
                    .accessibilityLabel(label)
            }
    }
}

struct CanvasEditorSave: PreferenceKey {
    static var defaultValue: (() -> Bool)? { nil }
    static func reduce(value: inout (() -> Bool)?,nextValue: () -> (() -> Bool)?) {
        if let save = nextValue() { value = save }
    }
}

struct BookGraphInkInspector: View {
    @ObservedObject var reader: ReaderModel
    let original: ReaderPageNote
    let palette: BookGraphPalette
    @State private var note: ReaderPageNote
    @State private var baseline: ReaderPageNote
    @State private var status: String?
    @State private var showingEntities = false
    @State private var writingNote = false
    @FocusState private var noteFocused: Bool
    private let bookID: UUID?
    private let nodeMenu: (() -> Void)?
    private let revealSource: () -> Void
    private let discuss: (() -> Void)?
    private let resumeWriting: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    init(reader: ReaderModel,original: ReaderPageNote,palette: BookGraphPalette,nodeMenu: (() -> Void)? = nil,revealSource: @escaping () -> Void,
         discuss: (() -> Void)? = nil,resumeWriting: (() -> Void)? = nil) {
        self.reader=reader;self.original=original;self.palette=palette;bookID=reader.currentID
        self.nodeMenu=nodeMenu; self.revealSource=revealSource; self.discuss=discuss; self.resumeWriting=resumeWriting
        let draft=reader.readingNodeDrafts.first(where:{ $0.id == .init(.ink,original.id.uuidString) })
        let value: ReaderPageNote
        if let draft, case .ink(let saved)=draft.node.content { value=saved } else { value=original }
        _note=State(initialValue:value);_baseline=State(initialValue:original)
    }
    private var latest: ReaderPageNote { reader.currentPageNotes.first(where:{ $0.id==original.id }) ?? original }
    private var entityIDs: Binding<[UUID]> { Binding(get:{ note.entityIDs ?? [] },set:{ note.entityIDs=$0 }) }
    private var writtenText: String { note.text ?? "" }
    private var hasWrittenNote: Bool { !writtenText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    var body: some View {
        let parts = latest.inkParts
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if writingNote {
                        if let first = parts.first { markPreview(first,writing:true) }
                        noteEditor.id("ink-note-editor")
                    } else {
                        if let first = parts.first { source(first) }
                        noteActions
                        if hasWrittenNote {
                            Text(writtenText).font(.callout).textSelection(.enabled)
                                .accessibilityIdentifier("ink-written-note")
                        }
                        if let discuss {
                            Button("AI 对话",systemImage:"sparkles") { if persist() { discuss() } }.buttonStyle(.bordered)
                        }
                        ForEach(parts.dropFirst()) { part in
                            Divider().overlay(palette.line)
                            source(part)
                        }
                        Divider().overlay(palette.line)
                        DisclosureGroup(isExpanded:$showingEntities) {
                            BookGraphEntityPicker(reader:reader,ids:entityIDs,palette:palette,inline:true)
                        } label: {
                            HStack(spacing:8) {
                                Label("关联事物",systemImage:"link")
                                if !entityIDs.wrappedValue.isEmpty {
                                    Text(entityIDs.wrappedValue.count.formatted()).monospacedDigit()
                                }
                            }.font(.subheadline.weight(.medium)).frame(minHeight:44)
                        }.tint(palette.canvasAccent)
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }.padding(resumeWriting == nil ? 16 : 2).padding(.bottom,8)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .modifier(GraphCardContentSize(enabled:resumeWriting != nil))
            }
            .onChange(of:noteFocused) { focused in
                if focused { scroll.scrollTo("ink-note-editor",anchor:.bottom) }
            }
            .background {
                GeometryReader { viewport in
                    Color.clear.onChange(of:viewport.size.height) { _ in
                        if noteFocused { scroll.scrollTo("ink-note-editor",anchor:.bottom) }
                    }
                }
            }
        }.background(resumeWriting == nil ? palette.paper : Color.clear)
            .preference(key:CanvasEditorSave.self,value:resumeWriting != nil ? persist : nil)
            .task(id:note) {
                do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
                if !Task.isCancelled { persist() }
            }
            .onChange(of:latest) { value in
                if note.text==baseline.text && note.title==baseline.title && note.entityIDs==baseline.entityIDs && note.attributes==baseline.attributes { note=value }
                baseline=value
            }
            .onChange(of:scenePhase) { value in if value != .active { persist() } }
            .onDisappear { persist() }
    }
    private var noteActions: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:8) { writingButtons }
            VStack(spacing:6) { writingButtons }
        }.buttonStyle(.plain).font(.subheadline.weight(.semibold))
    }
    @ViewBuilder private var writingButtons: some View {
        Button { writingNote = true } label: {
            Label(hasWrittenNote ? "编辑笔记" : "写笔记",systemImage:"square.and.pencil")
                .fixedSize(horizontal:true,vertical:false)
                .frame(maxWidth:.infinity,minHeight:44)
                .foregroundStyle(palette.dark ? Color.black : .white)
                .background(palette.canvasAccent,in:RoundedRectangle(cornerRadius:10))
        }
        if let resumeWriting {
            Button { if persist() { resumeWriting() } } label: {
                Label("回原文书写",systemImage:"pencil.tip")
                    .fixedSize(horizontal:true,vertical:false)
                    .frame(maxWidth:.infinity,minHeight:44)
                    .foregroundStyle(palette.canvasAccent)
                    .background(palette.canvasAccent.opacity(0.10),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
    private var noteEditor: some View {
        HStack(alignment:.top,spacing:8) {
            TextEditor(text:Binding(get:{ writtenText },set:{ note.text = $0.isEmpty ? nil : $0 }))
                .font(.callout).scrollContentBackground(.hidden)
                .frame(height:96)
                .background(palette.canvasAccent.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                .focused($noteFocused).accessibilityLabel("手写标记的文字笔记")
            Button {
                guard persist() else { return }
                noteFocused = false
                writingNote = false
            } label: {
                Text("完成").frame(minWidth:44,minHeight:44).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(palette.canvasAccent)
                .accessibilityLabel("完成笔记")
        }.task {
            await Task.yield()
            if !Task.isCancelled { noteFocused = true }
        }
    }
    private func source(_ part: ReaderInkPart) -> some View {
        VStack(alignment:.leading,spacing:6) {
            if let nodeMenu { markPreview(part).onLongPressGesture(perform:nodeMenu) }
            else { markPreview(part) }
            HStack(spacing:12) {
                Label(part.anchor.chapter,systemImage:"book").foregroundStyle(palette.ink.opacity(0.72)).lineLimit(1)
                Spacer(minLength:4)
                Button {
                    if persist(), reader.go(part.sources.first?.id ?? part.anchor.locator) { revealSource() }
                } label: {
                    Text("查看原文").fixedSize().frame(minHeight:44).contentShape(Rectangle())
                }.disabled(reader.loading || reader.busy)
            }.font(.caption).buttonStyle(.plain).foregroundStyle(palette.canvasAccent)
        }
    }
    @ViewBuilder private func markPreview(_ part: ReaderInkPart,writing: Bool = false) -> some View {
        if let image = reader.pageInkPartImage(part) {
            inkPreview(image).scaledToFit()
                .frame(maxWidth:.infinity,maxHeight:writing ? 42 : resumeWriting == nil ? nil : 136,alignment:writing ? .leading : .center)
                .clipShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel("手写笔迹")
        } else if !part.quote.isEmpty {
            ReadingSourceCard(text:part.quote,lineLimit:writing ? 1 : nil,textID:"ink-source-excerpt")
        }
    }
    private func inkPreview(_ image: ReaderImage) -> Image {
        #if os(macOS)
        Image(nsImage:image).resizable()
        #else
        Image(uiImage:image).resizable()
        #endif
    }
    @discardableResult private func persist() -> Bool {
        guard let bookID,bookID==reader.currentID,reader.currentPageNotes.contains(where:{ $0.id==note.id }),
              note.text != baseline.text || note.title != baseline.title || note.entityIDs != baseline.entityIDs || note.attributes != baseline.attributes else { return true }
        let id=ReadingNodeID(.ink,note.id.uuidString)
        if reader.saveGraphInkMetadata(note) {
            baseline=note;status=resumeWriting == nil ? "已自动保存" : nil;try? reader.discardReadingNodeDraft(id,bookID:bookID)
            return true
        } else {
            do { try reader.keepReadingNodeDraft(.init(id:id,content:.ink(note)),bookID:bookID);status="已保留草稿，可重试保存" }
            catch { status="修改尚未保存，请保留当前页面重试" }
            return false
        }
    }
}

struct GraphWrappingLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize {
        arrangement(width:proposal.width ?? 300,subviews:subviews).size
    }
    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) {
        let result = arrangement(width:bounds.width,subviews:subviews)
        for (i,point) in result.points.enumerated() { subviews[i].place(at:CGPoint(x:bounds.minX+point.x,y:bounds.minY+point.y),anchor:.topLeading,proposal:.unspecified) }
    }
    private func arrangement(width: Double,subviews: Subviews) -> (size: CGSize,points: [CGPoint]) {
        var x = 0.0, y = 0.0, rowHeight = 0.0, points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight+8; rowHeight = 0 }
            points.append(CGPoint(x:x,y:y)); x += size.width+8; rowHeight = max(rowHeight,size.height)
        }
        return (CGSize(width:width,height:y+rowHeight),points)
    }
}
