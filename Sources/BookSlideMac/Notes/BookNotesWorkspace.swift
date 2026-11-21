import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

enum BookGraphSelection: Equatable {
    case chapter(Int?), note(String), discussion(String), entity(UUID), relation(UUID), connection(ReadingEdge.ID)
    case newEvent, newEntity(BookEntityKind), newConnection(ReadingNodeID?), newRelation(UUID?), highlights, entities
}
private struct BookGraphCreation: Identifiable {
    let id = UUID()
    let bookID: UUID
    let selection: BookGraphSelection
}
private struct BookGraphAssociationPlacement: Identifiable {
    let edge: ReadingEdge
    let source: CGRect
    let target: CGRect
    let label: CGRect
    let curve: BookGraphCurve
    var id: ReadingEdge.ID { edge.id }
}

struct ReadingGraphColors {
    let dark: Bool
    let canvas, card, ink, accent: ReaderSwatch

    init(theme: String) {
        var appearance = ReaderAppearance()
        appearance.theme = theme
        let page = appearance.pageSwatch
        let white = ReaderSwatch(0xFFFFFF)
        ink = appearance.inkSwatch
        dark = theme == "night"
        switch theme {
        case "night":
            canvas = page
            card = page.mixed(with:ink,fraction:0.075)
            accent = ReaderSwatch(0xAFCAAF)
        case "light":
            canvas = page.mixed(with:ink,fraction:0.035)
            card = page
            accent = ReaderSwatch(0x456554)
        default:
            canvas = page.mixed(with:white,fraction:0.38)
            card = page.mixed(with:white,fraction:0.74)
            accent = ReaderSwatch(0x755537)
        }
    }
    var muted: ReaderSwatch { card.mixed(with:ink,fraction:0.70) }
    var field: ReaderSwatch { card.mixed(with:ink,fraction:dark ? 0.07 : 0.045) }
    var line: ReaderSwatch { card.mixed(with:ink,fraction:dark ? 0.22 : 0.17) }
    var css: [String:String] {
        ["paper":canvas.css,"panel":card.css,"card":card.css,"ink":ink.css,"accent":accent.css,
         "on-accent":dark ? canvas.css : "#FFFFFF","line":line.css,
         "muted":muted.css,
         "root-card":card.mixed(with:accent,fraction:dark ? 0.19 : 0.13).css,
         "root-border":card.mixed(with:accent,fraction:0.34).css,
         "chapter-card":card.css,"selection-wash":accent.css + "38",
         "drop-card":card.mixed(with:accent,fraction:0.20).css,
         "branch":canvas.mixed(with:accent,fraction:0.52).css]
    }
}

struct BookGraphPalette {
    let dark: Bool
    let themeColors: ReadingGraphColors?
    init(dark: Bool, readingTheme: String? = nil) {
        themeColors = readingTheme.map(ReadingGraphColors.init(theme:))
        self.dark = themeColors?.dark ?? dark
    }
    #if os(iOS)
    private var traits: UITraitCollection { .init(userInterfaceStyle:dark ? .dark : .light) }
    var background: Color { themeColors?.canvas.color ?? (dark ? Color(uiColor:UIColor.secondarySystemBackground.resolvedColor(with:traits)) : Color(red:0.970,green:0.965,blue:0.953)) }
    var paper: Color { themeColors?.card.color ?? (dark ? Color(uiColor:UIColor.systemBackground.resolvedColor(with:traits)) : Color(red:0.996,green:0.992,blue:0.980)) }
    var ink: Color { themeColors?.ink.color ?? (dark ? Color(white:0.94) : Color(white:0.12)) }
    var accent: Color { themeColors?.accent.color ?? (dark ? Color(red:0.83,green:0.66,blue:0.48) : Color(red:0.56,green:0.38,blue:0.25)) }
    #else
    var background: Color { themeColors?.canvas.color ?? (dark ? Color(red:0.12,green:0.15,blue:0.14) : Color(red:0.974,green:0.960,blue:0.931)) }
    var paper: Color { themeColors?.card.color ?? (dark ? Color(red:0.15,green:0.18,blue:0.17) : Color(red:0.986,green:0.975,blue:0.951)) }
    var ink: Color { themeColors?.ink.color ?? (dark ? Color(red:0.87,green:0.89,blue:0.85) : Color(red:0.20,green:0.19,blue:0.16)) }
    var accent: Color { themeColors?.accent.color ?? (dark ? Color(red:0.68,green:0.81,blue:0.70) : Color(red:0.29,green:0.40,blue:0.32)) }
    #endif
    var line: Color { themeColors?.line.color ?? ink.opacity(dark ? 0.20 : 0.10) }
    var muted: Color { themeColors?.muted.color ?? .secondary }
    var field: Color { themeColors?.field.color ?? ink.opacity(0.045) }
    var canvasAccent: Color { themeColors?.accent.color ?? accent }
}

struct BookNotesWorkspace: View {
    @ObservedObject var reader: ReaderModel
    var readingCompanion = false
    var noteInputReady = true
    var closingDiscussion: ReaderAnnotationDraft?
    var closingEntity: ReaderAnnotationDraft?
    private let onClose: () -> Void
    @State private var closingWorkspace = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = BookGraphSelection.chapter(nil)
    @State private var chapterID: Int?
    @State private var chapterSource: String?
    @State private var query = ""
    @State private var zoom = 1.0
    @State private var fittingGraph = false
    @State private var focusRequest = UUID()
    @State private var includeFuture = false
    @State private var noteLimit = 6
    @State private var recovery = false
    @State private var reviewing = false
    @State private var searchAllBooks = false
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @State private var companionGraphExpanded = false
    @State private var companionNoteExpanded = false
    @State private var companionGraphRestingHeight: CGFloat = 420
    @State private var nodeComposerHeight: CGFloat = 200
    @State private var creation: BookGraphCreation?
    @State private var creationResult: (bookID:UUID,item:ReadingGraphSelection)?
    @State private var creationReturn: BookGraphSelection?
    @State private var canvasEditing: BookGraphSelection?
    @State private var canvasLinksToken: String?
    @State private var canvasLinkDetail: ReadingEdge.ID?
    @State private var canvasFailure: String?
    @State private var actionTopic: MindMapTopic?
    @State private var actionAnchor = CGRect.zero
    @State private var canvasCommand: MindMapCommand?
    @State private var canvasTopicRect: CGRect?
    @State private var canvasContentRect: CGRect?
    @State private var canvasNoteContentHeight: CGFloat?
    private var directCanvas: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }
    init(reader: ReaderModel,readingCompanion: Bool = false,noteInputReady: Bool = true,closingDiscussion: ReaderAnnotationDraft? = nil,closingEntity: ReaderAnnotationDraft? = nil,close: @escaping () -> Void) {
        self.reader = reader; self.readingCompanion = readingCompanion; self.noteInputReady = noteInputReady; self.onClose = close
        self.closingDiscussion = closingDiscussion; self.closingEntity = closingEntity
        let index = reader.bookNotesIndex
        var initial = BookGraphSelection.chapter(reader.currentNoteSectionID ?? reader.chapters.indices.first)
        var owner: String?
        if let selected = reader.selectedReadingItem {
            switch selected {
            case .node(let id):
                owner = id.owner
                switch id.kind {
                case .entity: if let uuid = UUID(uuidString:id.owner) { initial = .entity(uuid) }
                case .discussion,.message: initial = .discussion(id.owner)
                case .source: initial = id.local == "excerpt" ? .note(id.owner) : .discussion(id.owner)
                case .note,.ink: initial = .note(id.owner)
                }
            case .edge(let id):
                if let relationship = index.graph.edges.first(where:{ $0.id == id })?.relationship { initial = .relation(relationship.id) }
                else { initial = .connection(id) }
                owner = id.source.kind == .entity ? id.target.owner : id.source.owner
            }
        } else if let id = reader.graphNoteID ?? reader.annotationDraft?.id, index.notes.contains(where:{ $0.id == id }) {
            initial = reader.discussionNoteID == id ? .discussion(id) : .note(id); owner = id
        }
        let chapter = owner.flatMap { id in index.notes.first(where:{ $0.id == id })?.chapterID } ?? reader.currentNoteSectionID ?? reader.chapters.indices.first
        _selection = State(initialValue:initial)
        _chapterID = State(initialValue:chapter)
        _chapterSource = State(initialValue:chapter.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].href : nil })
    }
    private var companionDiscussion: Bool { activeNote?.id != nil && activeNote?.id == reader.discussionNoteID }
    private var selectedDiscussionDraft: ReaderAnnotationDraft? { reader.selectionDiscussion ?? closingDiscussion }
    private var selectedEntityDraft: ReaderAnnotationDraft? { reader.selectionEntity ?? closingEntity }
    private var focusedTranslation: Bool { directCanvas && readingCompanion && selectedDiscussionDraft?.translates == true }
    private var companionShowsInspector: Bool {
        if selectedDiscussionDraft != nil || selectedEntityDraft != nil || (searchAllBooks && !readingCompanion) { return true }
        if case .chapter = selection { return false }
        return true
    }
    private var companionNodeCreating: Bool {
        if companionCreating { if case .newEntity = selection { return true }; return false }
        return selectedEntityDraft != nil
    }
    private var companionOrganizing: Bool {
        switch selection {
        case .entities, .entity, .relation, .connection, .newEvent, .newEntity, .newConnection, .newRelation: return true
        default: return false
        }
    }
    private var companionCreating: Bool {
        switch selection { case .newEvent, .newEntity, .newConnection, .newRelation: return true; default: return false }
    }
    private var readProgress: Double { reader.noteVisibilityProgress }
    private var visibleNotes: [BookGraphNote] { index.visibleNotes(through:readProgress,includeFuture:includeFuture) }
    private var palette: BookGraphPalette { .init(dark:colorScheme == .dark,readingTheme:readingCompanion || directCanvas ? reader.appearance.theme : nil) }
    private var index: BookNotesIndex { reader.bookNotesIndex }
    private var activeNote: BookGraphNote? {
        switch selection {
        case .note(let id), .discussion(let id): return index.notes.first { $0.id == id }
        default: break
        }
        if case .relation(let id) = selection, let relation = index.relations.first(where: { $0.id == id }) {
            return index.notes.first { relation.evidenceIDs.contains($0.id) }
        }
        return nil
    }
    private var readingChapter: Int? { reader.currentNoteSectionID }
    private var selectedConnection: ReadingEdge? {
        if case .connection(let id) = selection { return index.graph.edges.first { $0.id == id && $0.deletedAt == nil } }
        if case .relation(let id) = selection { return index.graph.edges.first { $0.relationship?.id == id && $0.deletedAt == nil } }
        return nil
    }
    private var connectionEndpoints: [ReadingNodeID] {
        selectedConnection.map { [$0.id.source,$0.id.target] } ?? []
    }
    private var graphNotes: [BookGraphNote] {
        var values: [BookGraphNote]
        if !readingCompanion && !searchAllBooks && !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { values = index.search(query) }
        else { values = reviewing ? index.notes : index.notes(in:chapterID) }
        for id in connectionEndpoints where id.kind != .entity && !values.contains(where:{ $0.id == id.owner }) {
            if let note = index.notes.first(where:{ $0.id == id.owner }) { values.append(note) }
        }
        let owners = Set(values.map(\.id))
        var subjects = Set(values.flatMap(\.entityIDs).map(\.uuidString))
        if case .entity(let id) = selection { subjects.insert(id.uuidString) }
        func contains(_ id: ReadingNodeID) -> Bool { id.kind == .entity ? subjects.contains(id.owner) : owners.contains(id.owner) }
        var seen = owners
        for edge in index.associations {
            let target: ReadingNodeID?
            if contains(edge.id.source) { target = edge.id.target } else if contains(edge.id.target) { target = edge.id.source } else { target = nil }
            if let target, target.kind != .entity, !seen.contains(target.owner), let note = index.notes.first(where:{ $0.id == target.owner }) { values.append(note); seen.insert(note.id) }
        }
        let drafts = Set(reader.textNoteDrafts.map(\.id))
        let progress = readProgress
        return values.filter { (includeFuture || $0.progress <= progress + 0.0001 || $0.id == activeNote?.id || drafts.contains($0.id) || $0.id == reader.annotationDraft?.id) }
    }
    private var chapterRows: [Int] { index.structure.nodes.map(\.id) }
    private var shownRelations: [BookRelation] {
        let revealedProgress = max(readProgress,activeNote?.progress ?? 0)
        let values = index.visibleRelations(through:revealedProgress,includeFuture:includeFuture)
        if selection == .entities { return values }
        let ids = Set(graphNotes.map(\.id))
        let href = chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].href : nil }
        return values.filter { relation in
            let selected: Bool
            if case .relation(let id) = selection { selected = id == relation.id } else { selected = false }
            return selected || reviewing || !Set(relation.evidenceIDs).isDisjoint(with:ids)
                || (relation.standalone == true && relation.chapterHref.map(BookNotesIndex.normalized) == href.map(BookNotesIndex.normalized))
        }
    }
    private var shownEntities: [BookEntity] {
        var ids = connectionEndpoints.filter { $0.kind == .entity }.compactMap { UUID(uuidString:$0.owner) }
        ids += shownRelations.flatMap { [$0.sourceID,$0.targetID] }
        ids += shownAssociations.flatMap { edge in [edge.id.source,edge.id.target].filter { $0.kind == .entity }.compactMap { UUID(uuidString:$0.owner) } }
        if case .entity(let id) = selection, !ids.contains(id) { ids.append(id) }
        ids += graphNotes.flatMap(\.entityIDs)
        let href = chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].href : nil }
        ids += index.entities.filter { entity in
            (includeFuture || (entity.progress ?? 0) <= readProgress + 0.0001) && (reviewing || entity.chapterHref.map(BookNotesIndex.normalized) == href.map(BookNotesIndex.normalized))
        }.map(\.id)
        var seen = Set<UUID>()
        if selection == .entities { return index.matchingEntities(through:readProgress,includeFuture:includeFuture) }
        return ids.filter { seen.insert($0).inserted }.prefix(12).compactMap { id in index.entities.first { $0.id == id } }
    }
    private var shownAssociations: [ReadingEdge] {
        guard !index.associations.isEmpty else { return [] }
        let owners = Set(graphNotes.map(\.id))
        let visible = Set(index.searchNodes("",through:readProgress,includeFuture:includeFuture).map(\.id))
        let selectedEntity: String?
        if case .entity(let id) = selection { selectedEntity = id.uuidString } else { selectedEntity = nil }
        return index.associations.filter { edge in
            visible.contains(edge.id.source) && visible.contains(edge.id.target) &&
                (edge.id == selectedConnection?.id || owners.contains(edge.id.source.owner) || owners.contains(edge.id.target.owner) || edge.id.source.owner == selectedEntity || edge.id.target.owner == selectedEntity)
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let detailFocused = !directCanvas && (selectedDiscussionDraft != nil || selectedEntityDraft != nil || companionCreating || companionDiscussion || companionNoteExpanded || (activeNote != nil && geometry.size.height < 520 && !searchVisible))
            VStack(spacing:0) {
                if readingCompanion {
                    if !directCanvas && !detailFocused { companionToolbar }
                }
                else { toolbar(compact:geometry.size.width < 1000) }
                if !readingCompanion { Divider() }
                if directCanvas {
                    directGraph
                        .overlay(alignment:.top) {
                            if readingCompanion && !focusedTranslation {
                                companionToolbar.padding(.horizontal,12).padding(.top,12)
                            }
                        }
                } else if readingCompanion {
                    // Keep the search field mounted when the keyboard reduces
                    // the available height, so its input session stays active.
                    let editorHeight = min(companionOrganizing ? 330 : 280,max(210,geometry.size.height * (companionOrganizing ? 0.38 : 0.29)))
                    let composerHeight = min(nodeComposerHeight,geometry.size.height)
                    let graphHeight = companionNodeCreating ? (geometry.size.height < 520 ? 0 : max(0,geometry.size.height-composerHeight-0.5))
                        : detailFocused ? (companionGraphExpanded ? min(210,geometry.size.height * 0.25) : 0)
                        : companionCreating ? min(230,geometry.size.height * 0.3) : max(0,geometry.size.height-52-(companionShowsInspector ? editorHeight : 0))
                    VStack(spacing:0) {
                        // Keep the same viewport alive while the keyboard
                        // folds the preview, preserving its pan and zoom.
                        companionGraph
                            .frame(height:detailFocused ? companionGraphRestingHeight : graphHeight)
                            .frame(height:graphHeight,alignment:.center).clipped().contentShape(Rectangle())
                            .allowsHitTesting(!companionNodeCreating && (!detailFocused || companionGraphExpanded))
                            .accessibilityHidden(companionNodeCreating || (detailFocused && !companionGraphExpanded))
                            .onAppear { if graphHeight > 0 && (!detailFocused || (companionNodeCreating && geometry.size.height >= 520)) { companionGraphRestingHeight = graphHeight } }
                            .onChange(of:graphHeight) { height in if height > 0 && (!detailFocused || (companionNodeCreating && geometry.size.height >= 520)) { companionGraphRestingHeight = height } }
                    }.animation(reduceMotion ? nil : .easeInOut(duration:0.20),value:detailFocused)
                        .animation(reduceMotion ? nil : .easeInOut(duration:0.20),value:companionGraphExpanded)
                    if companionNodeCreating {
                        if graphHeight > 0 { Rectangle().fill(palette.line).frame(height:0.5) }
                        inspector.frame(height:composerHeight)
                            .environment(\.readingCompanionChrome,ReadingCompanionChrome(tools:AnyView(companionTools),ink:reader.appearance.ink))
                            .onPreferenceChange(ReadingNodeComposerHeight.self) { if $0 > 0 { nodeComposerHeight = max(140,$0) } }
                    } else if companionShowsInspector {
                        if graphHeight > 0 { Rectangle().fill(palette.line.opacity(0.5)).frame(height:0.5) }
                        inspector.frame(height:detailFocused || companionCreating ? nil : editorHeight)
                            .frame(maxHeight:detailFocused || companionCreating ? .infinity : nil)
                            .environment(\.readingCompanionChrome,detailFocused ? ReadingCompanionChrome(tools:AnyView(companionTools),ink:reader.appearance.ink) : nil)
                    }
                } else if geometry.size.width >= 900 {
                    HStack(spacing:0) {
                        graphArea
                        Divider()
                        inspector.frame(width:geometry.size.width >= 1300 ? 430 : geometry.size.width >= 1100 ? 360 : 320)
                    }
                } else {
                    VStack(spacing:0) {
                        // On a phone, editing takes the available height so
                        // the note never remains underneath the keyboard.
                        let focusedPhoneNote = geometry.size.width < 600 && activeNote != nil
                        graphArea.frame(height:focusedPhoneNote ? 0 : max(280,geometry.size.height * 0.46))
                            .clipped().accessibilityHidden(focusedPhoneNote)
                        if !focusedPhoneNote { Divider() }
                        inspector
                    }
                }
            }.background(palette.background).foregroundStyle(palette.ink).tint(palette.accent)
        }
        .onAppear { selectInitial() }
        .onChange(of:reader.loading) { loading in if !loading { selectInitial() } }
        .onChange(of:reader.currentID) { _ in
            canvasTopicRect = nil
            creation = nil
            creationReturn = nil; searchVisible = false; searchFocused = false
            query = ""; searchAllBooks = false; chapterID = nil; selection = .chapter(nil); companionNoteExpanded = false; fittingGraph = false
            canvasEditing = nil
        }
        .onChange(of:reader.graphNoteID) { id in if let id { select(reader.discussionNoteID == id ? .discussion(id) : .note(id)); focusRequest = UUID() } }
        .onChange(of:reader.selectedReadingItem) { item in
            if let item {
                if readingCompanion && !companionCreating {
                    reader.showNoteGraph = true
                    reader.selectionDiscussion = nil; reader.selectionEntity = nil
                }
                applyReadingSelection(item)
                if directCanvas, case .discussion = selection { canvasEditing = selection }
                if !directCanvas || canvasEditing != nil { focusRequest = UUID() }
            }
        }
        .onChange(of:reader.chapters.map(\.href)) { _ in
            if case .chapter = selection {
                select(.chapter(chapterSource.flatMap { href in reader.chapters.firstIndex { $0.href == href } } ?? readingChapter ?? reader.chapters.indices.first))
            } else if let item = reader.selectedReadingItem { applyReadingSelection(item) }
            else { select(selection) }
            // Body headings arrive after the initial TOC. Their insertion
            // changes node positions, so focus the same source in the new tree.
            focusRequest = UUID()
        }
        .onChange(of:query) { _ in
            // Typing searches; choosing a result navigates. In the companion,
            // keep the current editor and graph camera intact behind search.
            guard !readingCompanion else { return }
            noteLimit = 6
            guard !searchAllBooks else { return }
            if let node = index.searchNodes(query,through:readProgress,includeFuture:includeFuture).first, !query.isEmpty { reader.selectReadingItem(.node(node.id)) }
            else if let id = index.structure.nodes.first(where: { $0.entry.title.localizedCaseInsensitiveContains(query) })?.id, !query.isEmpty { select(.chapter(id)) }
            if !query.isEmpty { focusRequest = UUID() }
        }
        .overlay {
            if readingCompanion && searchVisible { companionSearch }
        }
        .overlay {
            if reader.loading || reader.downloadingBook != nil {
                VStack(spacing:12) {
                    ProgressView()
                    Text(reader.downloadingBook != nil ? "正在下载图书…" : "正在打开图书脉络…")
                    #if os(iOS)
                    if reader.downloadingBook != nil {
                        ProgressView(value:reader.downloadProgress).frame(width:180)
                        Button("取消下载") { reader.knowledgeOpenTask?.cancel() }
                    }
                    #endif
                }.padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
            }
        }
        .sheet(isPresented:$recovery) { ReaderNoteRecoveryView(reader:reader) }
        .sheet(item:$creation,onDismiss:finishCreation) { item in
            switch item.selection {
            case .newEvent:
                BookGraphEventComposer(reader:reader,palette:palette) { edge in
                    creationResult = (item.bookID,.edge(edge)); creation = nil
                }
            case .newEntity(let kind):
                BookGraphNewEntity(reader:reader,kind:kind,palette:palette,floating:true) { value in
                    if case .entity(let id) = value { creationResult = (item.bookID,.node(.init(.entity,id.uuidString))) }
                    creation = nil
                }
            case .newConnection(let source):
                ReadingNodeLinks(reader:reader,source:source,palette:palette,connected:{ creationResult = (item.bookID,.edge($0)) })
            default: EmptyView()
            }
        }
        .environment(\.readingGraphAccent,palette.themeColors?.accent.color)
        .environment(\.colorScheme,palette.dark ? .dark : .light)
    }
    private var connectionSource: ReadingNodeID? {
        switch reader.selectedReadingItem {
        case .node(let id): return index.graph.node(id) == nil ? nil : id
        case .edge(let id): return id.source
        case nil: return nil
        }
    }
    private var companionToolbar: some View {
        HStack(spacing:10) {
            ViewThatFits(in:.horizontal) {
                Text("阅读脉络").font(.system(size:14,weight:.semibold)).fixedSize().accessibilityIdentifier("reading-workspace-title")
                Color.clear.frame(width:0,height:0)
            }
            Spacer(minLength:0)
            if !directCanvas {
                Button { addNote() } label: { Label("笔记",systemImage:"square.and.pencil") }.font(.callout).frame(minHeight:44).accessibilityLabel("添加笔记").disabled(reader.loading || reader.busy)
                Button { navigate(.newEvent) } label: { Label("事件",systemImage:"arrow.triangle.branch") }.font(.callout).frame(minHeight:44).accessibilityLabel("添加事件").disabled(reader.loading || reader.busy)
            }
            HStack(spacing:directCanvas ? 0 : 10) {
                ReadingToolButton(symbol:"magnifyingglass",label:"搜索全书脉络") { searchVisible.toggle() }
                if directCanvas {
                    ReadingToolButton(symbol:reader.knowledgeCanvasExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",label:reader.knowledgeCanvasExpanded ? "收起画布" : "展开画布") { reader.knowledgeCanvasExpanded.toggle() }
                }
                companionTools
            }.padding(.horizontal,directCanvas ? 4 : 0)
                .modifier(BookNotesGlassSurface(palette:palette,shape:Capsule(),active:directCanvas))
        }.buttonStyle(.plain).padding(.horizontal,directCanvas ? 4 : 20)
            .padding(.top,directCanvas ? 0 : 8)
    }
    private var companionTools: some View {
        Group {
            if directCanvas {
                canvasRecoveryButton
            } else {
                Menu {
                    if !companionNodeCreating {
                        Button(companionGraphExpanded ? "收起结构图" : "展开结构图",systemImage:"point.3.connected.trianglepath.dotted") { companionGraphExpanded.toggle() }
                        Button("搜索全书脉络",systemImage:"magnifyingglass") { searchVisible = true }
                    }
                    Button("放大结构图",systemImage:"plus.magnifyingglass") { zoom = min(1.8,zoom+0.15) }
                    Button("缩小结构图",systemImage:"minus.magnifyingglass") { zoom = max(0.35,zoom-0.15) }
                    Divider()
                    Button("添加笔记",systemImage:"square.and.pencil") { addNote() }
                    Button("添加事件",systemImage:"arrow.triangle.branch") { navigate(.newEvent) }
                    Button("添加连接",systemImage:"point.3.connected.trianglepath.dotted") { navigate(.newConnection(connectionSource)) }
                    if reader.noteDraftCount > 0 || !reader.removedNotes.isEmpty {
                        Divider()
                        Button("草稿与最近删除",systemImage:"clock.arrow.circlepath") { recovery = true }
                    }
                } label: { Image(systemName:"point.3.connected.trianglepath.dotted").font(.system(size:16,weight:.medium)).frame(width:44,height:44) }
                    .accessibilityLabel("添加到图中").disabled(reader.loading)
            }
            Button(action:close) { Image(systemName:"xmark").font(.system(size:14,weight:.medium)).frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("收起笔记，继续阅读")
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var canvasRecoveryButton: some View {
        if reader.noteDraftCount > 0 || !reader.removedNotes.isEmpty {
            ReadingToolButton(symbol:"clock.arrow.circlepath",label:"草稿与最近删除") { recovery = true }
        }
    }
    private var companionGraph: some View {
        VStack(spacing:0) {
            if companionNodeCreating {
                Text("脉络预览").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.top,14).padding(.bottom,8)
            }
            GeometryReader { geometry in graphCanvas(viewport:geometry.size) }
        }.accessibilityIdentifier("companion-structure-graph")
    }
    private var companionSearch: some View {
        VStack(spacing:12) {
            HStack {
                Text("查找阅读记录").font(.headline)
                Spacer()
                Button("取消",action:finishCompanionSearch).frame(minWidth:44,minHeight:44)
                    .accessibilityLabel("取消搜索，返回笔记")
            }
            graphSearch
            if searchAllBooks {
                BookGraphSearchPanel(reader:reader,query:query,close:finishCompanionSearch)
            } else {
                let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
                let nodes = term.isEmpty ? [] : index.searchNodes(term,through:readProgress,includeFuture:includeFuture)
                let chapters = term.isEmpty ? [] : index.structure.nodes.filter { $0.entry.title.localizedCaseInsensitiveContains(term) }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        if term.isEmpty || (nodes.isEmpty && chapters.isEmpty) {
                            Text(term.isEmpty ? "搜索章节、笔记、事物或对话。" : "没有找到匹配的记录，试试其他关键词。")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical,16)
                        }
                        ForEach(chapters) { chapter in
                            Button {
                                select(.chapter(chapter.id)); focusRequest = UUID(); finishCompanionSearch()
                            } label: {
                                Label(chapter.entry.title,systemImage:"book")
                                    .frame(maxWidth:.infinity,minHeight:52,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                        ForEach(nodes) { node in
                            Button {
                                reader.selectReadingItem(.node(node.id)); focusRequest = UUID(); finishCompanionSearch()
                            } label: {
                                Text(node.canvasSearchText).font(.callout.weight(.medium)).lineLimit(2)
                                    .frame(maxWidth:.infinity,minHeight:52,alignment:.leading).padding(.vertical,10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("companion-search-result")
                            Divider()
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.scrollDismissesKeyboard(.interactively)
            }
        }.padding(.horizontal,20).padding(.top,8).padding(.bottom,12)
            .frame(maxWidth:.infinity,maxHeight:.infinity).background(palette.paper)
            .task { searchFocused = true }
    }
    private func finishCompanionSearch() {
        searchFocused = false; searchVisible = false; searchAllBooks = false; query = ""
    }
    @ViewBuilder private func toolbar(compact: Bool) -> some View {
        #if os(iOS)
        iPadToolbar(compact:compact)
        #else
        desktopToolbar(compact:compact)
        #endif
    }
    #if os(iOS)
    private func iPadToolbar(compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.center,spacing:16) {
                VStack(alignment:.leading,spacing:7) {
                    Text("脉络与笔记").font(.system(size:24,weight:.semibold)).accessibilityAddTraits(.isHeader)
                    Menu {
                        ForEach(reader.visibleBooks) { book in Button(book.title) { reader.openKnowledgeWorkspace(bookID:book.id) } }
                    } label: {
                        HStack(spacing:6) {
                            Text(reader.currentBook?.title ?? "选择图书").lineLimit(1)
                            Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold))
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }.accessibilityLabel("切换图书脉络").disabled(reader.loading || reader.busy || reader.downloadingBook != nil)
                }
                Spacer(minLength:0)
                Button { reviewing.toggle(); query = ""; select(.chapter(readingChapter)) } label: {
                    Image(systemName:reviewing ? "book" : "clock.arrow.circlepath").frame(width:44,height:44)
                }.buttonStyle(.plain).background(palette.paper,in:Circle())
                    .accessibilityLabel(reviewing ? "回到本章" : "回顾已读")
                if !compact {
                    Button { navigate(.entities) } label: { Label("事物与关系",systemImage:"point.3.connected.trianglepath.dotted") }
                        .buttonStyle(.bordered).accessibilityIdentifier("things-relations-entry")
                    if !directCanvas {
                        Button { navigate(.newEvent) } label: { Label("添加事件",systemImage:"arrow.triangle.branch") }.buttonStyle(.bordered).disabled(reader.loading || reader.busy)
                        Button { addNote() } label: { Label("添加笔记",systemImage:"square.and.pencil") }
                            .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(reader.loading || reader.busy)
                    }
                }
                if directCanvas && !compact {
                    canvasRecoveryButton
                } else if !directCanvas {
                    Menu {
                        Button("添加事件",systemImage:"arrow.triangle.branch") { navigate(.newEvent) }
                        Button("添加连接",systemImage:"point.3.connected.trianglepath.dotted") { navigate(.newConnection(connectionSource)) }
                    } label: { Image(systemName:"ellipsis").frame(width:44,height:44) }
                        .accessibilityLabel("添加事物或关系")
                }
                Button("完成",action:close).font(.subheadline.weight(.semibold)).frame(minWidth:52,minHeight:44)
                    .keyboardShortcut(.cancelAction).buttonStyle(.plain)
            }
            if compact {
                HStack {
                    if directCanvas { canvasRecoveryButton }
                    Button { navigate(.entities) } label: { Label("事物与关系",systemImage:"point.3.connected.trianglepath.dotted") }
                        .buttonStyle(.bordered).accessibilityIdentifier("things-relations-entry")
                    if !directCanvas {
                        Button { navigate(.newEvent) } label: { Label("添加事件",systemImage:"arrow.triangle.branch") }.buttonStyle(.bordered).disabled(reader.loading || reader.busy)
                        Button { addNote() } label: { Label("添加笔记",systemImage:"square.and.pencil") }
                            .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(reader.loading || reader.busy)
                    }
                }
            }
            graphSearch.frame(maxWidth:compact ? .infinity : 560)
        }.padding(.horizontal,compact ? 24 : 28).padding(.top,18).padding(.bottom,14)
    }
    #endif
    private func desktopToolbar(compact: Bool) -> some View {
        VStack(spacing:12) {
            HStack(spacing:compact ? 10 : 18) {
                Label(compact ? "脉络与笔记" : "全书脉络与笔记",systemImage:"point.3.connected.trianglepath.dotted").font(.headline)
                Menu {
                    ForEach(reader.visibleBooks) { book in
                        Button(book.title) { reader.openKnowledgeWorkspace(bookID:book.id) }
                    }
                } label: { Text(reader.currentBook?.title ?? "选择图书").font(.callout).lineLimit(1).frame(maxWidth:compact ? 170 : 260) }
                    .accessibilityLabel("切换图书脉络").disabled(reader.loading || reader.busy || reader.downloadingBook != nil)
                Spacer(minLength:4)
                if !compact { graphSearch.frame(maxWidth:430) }
                Button { reviewing.toggle(); query = ""; select(.chapter(readingChapter)) } label: { Label(reviewing ? (compact ? "本章" : "回到本章") : (compact ? "回顾" : "回顾已读"),systemImage:reviewing ? "book" : "clock.arrow.circlepath") }.buttonStyle(.borderless)
                Button { navigate(.entities) } label: { Label("事物与关系",systemImage:"point.3.connected.trianglepath.dotted") }
                    .buttonStyle(.bordered).accessibilityIdentifier("things-relations-entry")
                Button { navigate(.newEvent) } label: { Label("添加事件",systemImage:"arrow.triangle.branch") }.buttonStyle(.bordered).disabled(reader.loading || reader.busy)
                Button { addNote() } label: { Label("添加笔记",systemImage:"square.and.pencil") }
                    .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(reader.loading || reader.busy)
                Menu {
                    Button("添加事件",systemImage:"arrow.triangle.branch") { navigate(.newEvent) }
                    Button("添加连接",systemImage:"point.3.connected.trianglepath.dotted") { navigate(.newConnection(connectionSource)) }
                } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("添加事物或关系")
                Button("完成",action:close).keyboardShortcut(.cancelAction).buttonStyle(.borderless)
            }
            if compact { graphSearch }
        }.padding(.horizontal,22).padding(.top,22).padding(.bottom,16)
    }
    private var graphSearch: some View {
        HStack(spacing:12) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
            TextField(searchAllBooks ? "跨书查找笔记、事物" : "搜索章节、笔记、事物",text:$query).textFieldStyle(.plain).accessibilityLabel("搜索章节、记录、事物")
                .focused($searchFocused).accessibilityIdentifier("reading-record-search")
            if !query.isEmpty { Button { query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            Menu {
                Toggle("跨书查找",isOn:$searchAllBooks)
                Divider()
                Toggle("显示全部记录（含后文）",isOn:$includeFuture)
                Button("全部事物与关系") { selection = .entities }
                Divider()
                ForEach(Array(reader.chapters.enumerated()),id:\.offset) { id, chapter in
                    Button(String(repeating:"　",count:min(chapter.depth,3)) + chapter.title) { query = ""; select(.chapter(id)); focusRequest = UUID() }
                }
                if index.notes.contains(where: { $0.chapterID == nil }) { Button("未归类的笔记") { select(.chapter(nil)) } }
            } label: { Image(systemName:"list.bullet.indent") }.accessibilityLabel("章节与显示范围")
            Button { query = ""; select(.chapter(readingChapter ?? reader.chapters.indices.first)); focusRequest = UUID() } label: { Image(systemName:"scope") }.buttonStyle(.borderless).accessibilityLabel("定位当前章节")
        }.padding(11).background(palette.ink.opacity(0.035),in:RoundedRectangle(cornerRadius:11))
    }
    private var graphArea: some View {
        VStack(spacing:0) {
            HStack {
                Text(reviewing ? "回顾已读" : chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].title : nil } ?? "阅读记录").lineLimit(1)
                Spacer()
                if reader.noteDraftCount > 0 || !reader.removedNotes.isEmpty {
                    Button { recovery = true } label: { Label("草稿与最近删除",systemImage:"clock.arrow.circlepath") }.buttonStyle(.plain)
                }
                if let draft = reader.currentBook?.relationDrafts?.last {
                    Button("继续关系草稿") {
                        if let id = draft.originalID { selection = .relation(id) }
                        else { selection = .newRelation(draft.sourceID) }
                    }.buttonStyle(.plain)
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,16)
            GeometryReader { geometry in
                graphCanvas(viewport:geometry.size)
            }
            HStack(spacing:12) {
                Text("拖动查看").foregroundStyle(.secondary).lineLimit(1)
                NoteExportButton(reader:reader,records:LibraryNotes.records(in:reader.currentBook.map { [$0] } ?? []).filter { record in graphNotes.contains { $0.id == record.note.id } },title:reader.currentBook?.title ?? "读书笔记",compact:false)
                Spacer(minLength:4)
                Button { zoom = max(0.35,zoom-0.1) } label: { Image(systemName:"minus") }.accessibilityLabel("缩小脉络")
                Button { zoom = 1; fittingGraph = true; focusRequest = UUID() } label: { Text(zoom == 1 ? "适应视野" : "\(Int(zoom*100))%").monospacedDigit() }.accessibilityLabel("适应视野，显示完整关联内容")
                Button { zoom = min(2,zoom+0.1) } label: { Image(systemName:"plus") }.accessibilityLabel("放大脉络")
            }.font(.caption).buttonStyle(.borderless).padding(20)
        }
    }
    private func graphCanvas(viewport: CGSize) -> some View {
        let endpoints = Set(connectionEndpoints.filter { $0.kind != .entity }.map(\.owner))
        let highlights = graphNotes.filter { $0.highlightOnly && $0.id != activeNote?.id && !endpoints.contains($0.id) }
        let candidates = graphNotes.filter { $0.showsOnCanvas || $0.id == activeNote?.id || endpoints.contains($0.id) }
        let ordered = candidates.filter { endpoints.contains($0.id) } + candidates.filter { !endpoints.contains($0.id) }
        let notes = Array(ordered.prefix(noteLimit)), entities = shownEntities
        let discussions = index.discussions.filter { thread in notes.contains { $0.id == thread.noteID } }
        let chapters = chapterRows
        let focusRow = chapters.firstIndex(of:chapterID ?? -1) ?? 0
        let tree = index.structure.layout(visible:chapters,rowHeight:chapters.count > 10 ? 128 : 112)
        var positions = tree.placements.map { CGRect(x:24+Double(index.structure.nodes[$0.id].depth+1)*206,y:$0.y+40,width:180,height:84) }
        if chapters.isEmpty { positions.append(CGRect(x:230,y:210,width:180,height:84)) }
        let chapterRect = positions[min(focusRow,positions.count-1)]
        let chapterY = chapterRect.midY
        let noteX = max(310,(positions.map(\.maxX).max() ?? 250)+72)
        let entityX = noteX+(readingCompanion ? 344 : 68)
        let startY = max(50,chapterY-60)
        // Keep cards readable at their natural size. The canvas extends beyond
        // the viewport; its branches are explored by panning, not squeezed in.
        let noteWidth = 208.0, noteHeight = 80.0, discussionHeight = 80.0
        var nextY = startY
        let noteRects = notes.map { note -> CGRect in
            let rect = CGRect(x:noteX,y:nextY,width:noteWidth,height:noteHeight)
            nextY += rect.height+(readingCompanion && discussions.contains(where:{ $0.noteID == note.id }) ? 192 : 64)
            return rect
        }
        let groupY = nextY
        let discussionRects = discussions.map { thread -> CGRect in
            let row = notes.firstIndex { $0.id == thread.noteID } ?? 0
            return CGRect(x:readingCompanion ? noteX+28 : noteX+280,y:readingCompanion ? noteRects[row].maxY+48 : noteRects[row].minY,width:noteWidth,height:discussionHeight)
        }
        let entityY = readingCompanion ? startY+6 : max(nextY,(noteRects.map(\.maxY).max() ?? startY)+134)+(highlights.isEmpty ? 0 : 136)
        let entityStep = readingCompanion ? 160.0 : 174.0, entityHeight = 60.0
        positions += noteRects
        positions += entities.enumerated().map { i,_ in
            CGRect(x:entityX+(readingCompanion ? 0 : Double(i%2)*308),y:entityY+Double(readingCompanion ? i : i/2)*entityStep,width:144,height:entityHeight)
        }
        let noteOffset = max(1,chapters.count), entityOffset = noteOffset + notes.count
        let labelRelations = shownRelations.filter { relation in entities.contains(where: { $0.id == relation.sourceID }) && entities.contains(where: { $0.id == relation.targetID }) }
        let bookRect = CGRect(x:24,y:tree.rootY+40,width:160,height:84)
        var cardObstacles = positions+discussionRects+[bookRect]
        if !highlights.isEmpty { cardObstacles.append(CGRect(x:noteX,y:groupY,width:280,height:90)) }
        let relationCurves = labelRelations.map { relation in
            let a = entities.firstIndex { $0.id == relation.sourceID }!, b = entities.firstIndex { $0.id == relation.targetID }!
            return BookGraphRouting.connection(from:positions[entityOffset+a],to:positions[entityOffset+b],obstacles:cardObstacles)
        }
        var labelObstacles = cardObstacles
        let relationRects = relationCurves.map { curve -> CGRect in
            let label = BookGraphRouting.label(on:curve,obstacles:labelObstacles)
            labelObstacles.append(label)
            return label
        }
        positions += relationRects
        let discussionOffset = positions.count
        positions += discussionRects
        func nodeRect(_ id: ReadingNodeID) -> CGRect? {
            switch id.kind {
            case .entity: return entities.firstIndex(where:{ $0.id.uuidString == id.owner }).map { positions[entityOffset+$0] }
            case .discussion, .message: return discussions.firstIndex(where:{ $0.noteID == id.owner }).map { discussionRects[$0] }
            case .source where id.local != "excerpt": return discussions.firstIndex(where:{ $0.noteID == id.owner }).map { discussionRects[$0] }
            default: return notes.firstIndex(where:{ $0.id == id.owner }).map { positions[noteOffset+$0] }
            }
        }
        let associations: [BookGraphAssociationPlacement] = shownAssociations.compactMap { edge in
            guard let source = nodeRect(edge.id.source), let target = nodeRect(edge.id.target), source != target else { return nil }
            let curve = BookGraphRouting.connection(from:source,to:target,obstacles:cardObstacles)
            let label = BookGraphRouting.label(on:curve,obstacles:labelObstacles)
            labelObstacles.append(label)
            return .init(edge:edge,source:source,target:target,label:label,curve:curve)
        }
        positions += associations.map(\.label)
        if !highlights.isEmpty { positions.append(CGRect(x:noteX,y:groupY,width:280,height:90)) }
        if notes.isEmpty && highlights.isEmpty && entities.isEmpty { positions.append(CGRect(x:noteX,y:max(90,chapterY-20),width:330,height:180)) }
        positions.append(bookRect)
        var connections: [BookGraphLine] = []
        func connect(_ from: CGPoint,_ to: CGPoint,accent: Bool = false) {
            var path = Path(); path.move(to:from)
            let bend = max(12,min(40,abs(to.x-from.x)*0.45))
            path.addCurve(to:to,control1:CGPoint(x:from.x+bend,y:from.y),control2:CGPoint(x:to.x-bend,y:to.y))
            connections.append(BookGraphLine(path:path.cgPath,accent:accent,width:accent ? 1.7 : 1.15))
        }
        for root in index.structure.roots {
            guard let row = chapters.firstIndex(of:root) else { continue }
            let q = positions[row]
            connect(CGPoint(x:bookRect.maxX,y:bookRect.midY),CGPoint(x:q.minX,y:q.midY),accent:root == chapterID)
        }
        for (row,id) in chapters.enumerated() {
            if let parent = index.structure.nodes[id].parent, let parentRow = chapters.firstIndex(of:parent) {
                let p = positions[parentRow], q = positions[row]
                connect(CGPoint(x:p.maxX,y:p.midY),CGPoint(x:q.minX,y:q.midY),accent:parent == chapterID || id == chapterID)
            }
        }
        for i in notes.indices {
            guard let owner = chapters.firstIndex(of:notes[i].chapterID ?? -1) else { continue }
            let p = positions[owner]
            connect(CGPoint(x:p.maxX,y:p.midY),CGPoint(x:noteX,y:positions[noteOffset+i].midY),accent:notes[i].id == activeNote?.id)
        }
        if !highlights.isEmpty {
            for owner in Set(highlights.compactMap(\.chapterID)) {
                guard let row = chapters.firstIndex(of:owner) else { continue }
                let p = positions[row]
                connect(CGPoint(x:p.maxX,y:p.midY),CGPoint(x:noteX,y:groupY+45))
            }
        }
        func drawCurve(_ curve: BookGraphCurve,accent: Bool = false,arrow: Bool = false) {
            let points = curve.points
            guard points.count > 1 else { return }
            connections.append(.init(path:curve.path,accent:accent,width:accent ? 1.6 : 1.1))
            if arrow, let end = points.last {
                let previous = points[points.count-2]
                let length = max(1,hypot(end.x-previous.x,end.y-previous.y))
                let dx = (end.x-previous.x)/length, dy = (end.y-previous.y)/length
                var tip = Path(); tip.move(to:CGPoint(x:end.x-dx*7-dy*4,y:end.y-dy*7+dx*4))
                tip.addLine(to:end); tip.addLine(to:CGPoint(x:end.x-dx*7+dy*4,y:end.y-dy*7-dx*4))
                connections.append(.init(path:tip.cgPath,accent:accent,width:1.5))
            }
        }
        func connectCards(_ source: CGRect,_ target: CGRect,accent: Bool = false,arrow: Bool = false) {
            drawCurve(BookGraphRouting.connection(from:source,to:target,obstacles:cardObstacles),accent:accent,arrow:arrow)
        }
        // Collapse provenance into the chapter-to-entity branch instead of
        // inventing a same-name thought card between them.
        let collapsedSources = graphNotes.filter { source in source.entitySourceOnly && !notes.contains { $0.id == source.id } }
        for i in entities.indices {
            let owners = Set(collapsedSources.filter { $0.entityIDs.contains(entities[i].id) }.map { $0.chapterID ?? -1 })
            for owner in owners.sorted() {
                if let row = chapters.firstIndex(of:owner) ?? (chapters.isEmpty ? 0 : nil) {
                    connectCards(positions[row],positions[entityOffset+i])
                }
            }
        }
        for row in notes.indices {
            let note = notes[row], rect = positions[noteOffset+row]
            for i in entities.indices where note.entityIDs.contains(entities[i].id) {
                // An explicit connection already explains this pair. Avoid a
                // second unlabelled wire on top of the same association.
                let target = ReadingNodeID(.entity,entities[i].id.uuidString)
                let source = ReadingNodeID(.note,note.id)
                if associations.contains(where:{ ($0.id.source == source && $0.id.target == target) || ($0.id.source == target && $0.id.target == source) }) { continue }
                connectCards(rect,positions[entityOffset+i])
            }
            if let response = note.responseToID, let previous = notes.firstIndex(where:{ $0.id == response }) {
                connectCards(positions[noteOffset+previous],rect,accent:true,arrow:true)
            }
        }
        for (i,thread) in discussions.enumerated() {
            if let row = notes.firstIndex(where:{ $0.id == thread.noteID }) {
                connectCards(positions[noteOffset+row],discussionRects[i],accent:selection == .discussion(thread.noteID))
            }
        }
        for association in associations {
            let selected = selection == .connection(association.id)
            drawCurve(association.curve,accent:selected,arrow:true)
        }
        for (i,relation) in labelRelations.enumerated() {
            let selected = selection == .relation(relation.id)
            drawCurve(relationCurves[i],accent:selected,arrow:true)
        }
        let contentBounds = positions.reduce(CGRect.null) { $0.union($1) }
        let canvasWidth = max(640,contentBounds.maxX+28,connections.map { $0.path.boundingBoxOfPath.maxX+28 }.max() ?? 0)
        let height = max(480,tree.height+140,contentBounds.maxY+28,connections.map { $0.path.boundingBoxOfPath.maxY+28 }.max() ?? 0)
        // Overview is an explicit action. Adding a person or a long connection
        // must never shrink every card in the reading canvas.
        let baseScale = fittingGraph ? BookGraphViewportPosition.overviewScale(canvas:CGSize(width:canvasWidth,height:height),viewport:viewport) : 1
        let scale = baseScale*zoom
        let canvas = BookNoteNodeLayout(positions:positions,size:CGSize(width:canvasWidth,height:height),scale:scale) {
            ForEach(chapters,id:\.self) { id in chapterCard(id).modifier(BookNodeScale(width:180,height:84,scale:scale)).id("chapter-\(id)") }
            if chapters.isEmpty { chapterCard(nil).modifier(BookNodeScale(width:180,height:84,scale:scale)).id("chapter--1") }
            ForEach(notes) { note in noteCard(note).modifier(BookNodeScale(width:noteWidth,height:noteHeight,scale:scale)).id("note-" + note.id) }
            ForEach(entities) { entity in
                Button { select(.entity(entity.id)) } label: {
                    Label(entity.name,systemImage:entity.kind.symbol).font(.system(size:17,weight:.medium)).lineLimit(1).frame(maxWidth:.infinity,maxHeight:.infinity)
                }.buttonStyle(.plain).background(selection == .entity(entity.id) ? palette.accent.opacity(0.07) : palette.paper,in:RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(selection == .entity(entity.id) ? palette.accent.opacity(0.65) : palette.line,lineWidth:1).allowsHitTesting(false))
                    .modifier(BookNodeScale(width:144,height:entityHeight,scale:scale)).id("entity-\(entity.id)")
                    .accessibilityIdentifier("graph-entity-\(entity.id)").accessibilityLabel("\(entity.kind.title)：\(entity.name)，查看关联笔记")
            }
            ForEach(labelRelations) { relation in
                Button { select(.relation(relation.id)) } label: {
                    Text((relation.conjecture ? "推测 · " : "") + relation.label).font(.system(size:14,weight:.medium)).lineLimit(1).padding(.horizontal,4)
                        .background(palette.background)
                }.buttonStyle(.plain).foregroundStyle(selection == .relation(relation.id) ? palette.accent : palette.ink.opacity(0.5))
                    .modifier(BookNodeScale(width:110,height:44,scale:scale))
                    .accessibilityIdentifier("graph-relation-\(relation.id)").accessibilityLabel("关系：\(relation.label)，查看原文依据")
            }
            ForEach(discussions) { thread in
                Button { select(.discussion(thread.noteID)) } label: {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:"bubble.left.and.bubble.right").font(.system(size:14)).foregroundStyle(.secondary)
                        VStack(alignment:.leading,spacing:5) {
                            Text(thread.title).font(.system(size:14,weight:.medium)).lineLimit(2)
                            Text("AI 对话 · \(thread.messageCount) 条消息").font(.system(size:10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0)
                    }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).background(palette.paper,in:RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(selection == .discussion(thread.noteID) ? palette.accent.opacity(0.65) : palette.line,lineWidth:1))
                    .modifier(BookNodeScale(width:noteWidth,height:discussionHeight,scale:scale)).accessibilityIdentifier("graph-discussion-\(thread.noteID)")
            }
            ForEach(associations) { association in
                Button { select(.connection(association.id)) } label: {
                    Text(association.edge.label).font(.system(size:13,weight:.medium)).foregroundStyle(selection == .connection(association.id) ? palette.accent : palette.ink.opacity(0.5))
                        .padding(.horizontal,7).background(palette.background,in:Capsule()).frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(BookNodeScale(width:110,height:44,scale:scale)).accessibilityLabel("节点连接：\(association.edge.label)")
            }
            if !highlights.isEmpty {
                Button { selection = .highlights } label: {
                    VStack(alignment:.leading,spacing:10) {
                        Label("\(highlights.count) 处划线摘录",systemImage:"text.quote").font(.headline)
                        Text("已收纳 · 点开查看原句").font(.callout).foregroundStyle(.secondary)
                    }.padding(18).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
                }.buttonStyle(.plain).background(palette.paper,in:RoundedRectangle(cornerRadius:12))
                    .overlay(RoundedRectangle(cornerRadius:12).stroke(palette.line).allowsHitTesting(false))
                    .modifier(BookNodeScale(width:280,height:90,scale:scale))
            }
            if notes.isEmpty && highlights.isEmpty && entities.isEmpty && !readingCompanion {
                VStack(alignment:.leading,spacing:16) {
                    Label(query.isEmpty ? "把想法留在这一章" : "没有匹配的笔记",systemImage:"square.and.pencil").font(.headline)
                    Text(query.isEmpty ? "摘录、想法和手写都会出现在这里。关联事物后，脉络会自然展开。" : "试试其他关键词，或清空搜索。").font(.callout).foregroundStyle(.secondary)
                    Button("添加笔记") { addNote() }.buttonStyle(.borderless)
                }.padding(22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).modifier(BookNodeScale(width:330,height:180,scale:scale))
            }
            Button { select(.chapter(readingChapter)); focusRequest = UUID() } label: {
                VStack(alignment:.leading,spacing:6) {
                    Label("全书",systemImage:"book.closed").font(.system(size:14,weight:.medium))
                    Text(reader.currentBook?.title ?? "阅读记录").font(.system(size:12,design:.serif)).foregroundStyle(.secondary).lineLimit(2)
                }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            }.buttonStyle(.plain).background(palette.paper,in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(palette.line,lineWidth:0.75))
                .modifier(BookNodeScale(width:160,height:84,scale:scale)).accessibilityLabel("图书结构起点")
                .contextMenu { Button("AI 对话",systemImage:"bubble.left.and.bubble.right") { showDiscussion(reader.beginReadingNodeDiscussion(chapter:nil)) } }
        }.background {
            BookGraphConnections(lines:connections,scale:scale,palette:palette).allowsHitTesting(false).accessibilityHidden(true)
        }.overlay(alignment:.bottomLeading) {
            if graphNotes.filter(\.showsOnCanvas).count > noteLimit { Button("展开更多记录") { noteLimit += 12 }.padding(.leading,noteX*scale).padding(.bottom,16) }
        }.frame(width:canvasWidth*scale,height:height*scale)
        func cardFocus(_ rect: CGRect) -> CGPoint {
            let y = readingCompanion && viewport.height > rect.height*scale+64 ? rect.minY+(viewport.height/2-32)/scale : rect.midY
            return CGPoint(x:rect.midX,y:y)
        }
        let focus: CGPoint
        switch selection {
        case .discussion(let id):
            if let i = discussions.firstIndex(where:{ $0.noteID == id }) {
                focus = cardFocus(positions[discussionOffset+i])
            } else { focus = CGPoint(x:chapterRect.midX,y:chapterY) }
        case .entities: focus = CGPoint(x:entityX+165,y:entityY+80)
        case .note(let id): focus = notes.firstIndex(where: { $0.id == id }).map { cardFocus(positions[noteOffset+$0]) } ?? CGPoint(x:chapterRect.midX,y:chapterY)
        case .entity(let id): focus = entities.firstIndex(where: { $0.id == id }).map { CGPoint(x:positions[entityOffset+$0].midX,y:positions[entityOffset+$0].midY) } ?? CGPoint(x:chapterRect.midX,y:chapterY)
        case .relation(let id):
            if let i = labelRelations.firstIndex(where:{ $0.id == id }) {
                focus = CGPoint(x:relationRects[i].midX,y:relationRects[i].midY)
            } else { focus = CGPoint(x:chapterRect.midX,y:chapterY) }
        case .connection(let id):
            if let association = associations.first(where:{ $0.id == id }) {
                focus = CGPoint(x:association.label.midX,y:association.label.midY)
            } else { focus = CGPoint(x:chapterRect.midX,y:chapterY) }
        default:
            let directChildren = chapterID.flatMap { index.structure.nodes.indices.contains($0) ? index.structure.nodes[$0].children : nil } ?? []
            let childRects = chapters.enumerated().filter { directChildren.contains($0.element) }.map { positions[$0.offset] }
            // Show the chapter and its child branches together on entry.
            focus = CGPoint(x:childRects.isEmpty ? chapterRect.midX : (chapterRect.minX+(childRects.map(\.maxX).max() ?? chapterRect.maxX))/2,y:chapterY)
        }
        return BookGraphViewport(content:canvas,canvasSize:CGSize(width:canvasWidth*scale,height:height*scale),scale:scale,focus:CGPoint(x:(canvasWidth*scale <= viewport.width && height*scale <= viewport.height ? canvasWidth/2 : focus.x)*scale,y:(height*scale <= viewport.height ? height/2 : focus.y)*scale),focusRequest:focusRequest)
    }
    private func chapterCard(_ id: Int?) -> some View {
        let chapter = id.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0] : nil }
        let progress = readProgress
        return HStack(spacing:8) {
            Button {
                if readingCompanion && !directCanvas, let id, !reader.openReadingChapter(id) { return }
                select(.chapter(id)); focusRequest = UUID()
            } label: {
                HStack(alignment:.top,spacing:10) {
                    Image(systemName:(chapter?.depth ?? 0) > 0 ? "text.alignleft" : "book.closed").padding(.top,2)
                    VStack(alignment:.leading,spacing:6) {
                        Text(chapter?.title ?? "未归类的笔记").font(.system(size:15,weight:chapterID == id ? .medium : .regular)).lineLimit(2).minimumScaleFactor(0.85)
                        HStack(spacing:8) {
                            if let id, index.structure.nodes[id].descendantCount > 0 {
                                Text("\(index.structure.nodes[id].descendantCount) 个小节").foregroundStyle(.secondary)
                            }
                            if let id {
                                let count = index.notes(in:id).filter { includeFuture || $0.progress <= progress + 0.0001 }.count
                                if count > 0 { Text("\(count) 条记录") }
                            }
                            if id != nil && id == readingChapter { Text("在读").foregroundStyle(palette.accent) }
                        }.font(.system(size:10)).lineLimit(1)
                    }
                    Spacer(minLength:0)
                }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(readingCompanion && (reader.busy || reader.loading))
                .accessibilityLabel((readingCompanion ? "阅读：" : "查看：") + (chapter?.title ?? "未归类的笔记"))
                .contextMenu {
                    if let chapter { Button("AI 对话",systemImage:"bubble.left.and.bubble.right") { showDiscussion(reader.beginReadingNodeDiscussion(chapter:chapter)) } }
                }
            if chapterID == id, case .chapter = selection { Button { addNote() } label: { Image(systemName:"plus.circle").frame(width:26,height:38) }.buttonStyle(.plain).padding(.trailing,5).accessibilityLabel("在此小节添加笔记") }
        }.accessibilityIdentifier("book-outline-node-\(id ?? -1)")
            .background(chapterID == id ? palette.accent.opacity(0.045) : palette.paper.opacity(0.65),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(chapterID == id ? palette.accent.opacity(0.28) : palette.line.opacity(0.65),lineWidth:0.75).allowsHitTesting(false))
    }
    private func noteCard(_ note: BookGraphNote) -> some View {
        let selected = selection == .note(note.id)
        let kind = note.question ? "问题" : note.entitySourceOnly ? "原文" : note.highlightOnly ? "摘录" : "想法"
        let content = (note.personalText ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        let displayText = content.isEmpty ? note.title : content
        return Button { select(.note(note.id)) } label: {
            Group {
                if note.ink {
                    inkCardPreview(note)
                } else {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:note.question ? "questionmark.bubble" : "note.text")
                            .font(.system(size:14)).foregroundStyle(.secondary).padding(.top,2)
                        VStack(alignment:.leading,spacing:5) {
                            Text(displayText).font(.system(size:14,weight:.semibold)).lineLimit(2)
                            Text(kind).font(.system(size:10)).foregroundStyle(.secondary)
                        }
                    }.padding(12)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:note.ink ? .center : .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).background(palette.paper,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(selected ? palette.accent.opacity(0.45) : palette.line,lineWidth:selected ? 1 : 0.75).allowsHitTesting(false))
            .accessibilityLabel(note.ink ? "手写标记，\(note.quote.isEmpty ? note.chapter : note.quote)" : "笔记：\(displayText)，\(note.chapter)")
    }
    @ViewBuilder private func inkCardPreview(_ note: BookGraphNote) -> some View {
        if let ink = reader.currentPageNotes.first(where:{ $0.id.uuidString == note.id }),
           let preview = reader.pageNoteImage(ink) {
            #if os(macOS)
            Image(nsImage:preview).resizable().scaledToFit().padding(8)
            #else
            Image(uiImage:preview).resizable().scaledToFit().padding(8)
            #endif
        } else {
            Text(note.quote.isEmpty ? "手写标记" : note.quote).font(.callout).lineLimit(2).padding(12)
        }
    }
    @ViewBuilder private var inspector: some View {
        if searchAllBooks && !readingCompanion {
            BookGraphSearchPanel(reader:reader,query:query) { searchAllBooks = false; query = "" }
        } else { selectedInspector }
    }
    @ViewBuilder private var selectedInspector: some View {
        if readingCompanion && !companionCreating, let draft = selectedEntityDraft {
            ReadingEntityFromSelection(reader:reader,draft:draft,embedded:true,cancel:{ reader.selectionEntity = nil },recorded:{ id in
                reader.showNoteGraph = true; reader.selectionEntity = nil; reader.selectionDiscussion = nil
                select(.entity(id)); focusRequest = UUID()
            }).id(draft.id)
        } else if readingCompanion && !companionCreating, let draft = selectedDiscussionDraft {
            ReaderSelectionDiscussion(reader:reader,draft:draft,embedded:true,connect:{ navigate(.newConnection($0)) }) {
                if directCanvas { canvasEditing = nil; reader.showNoteGraph = !draft.translates || draft.returnToGraph }
                reader.selectionDiscussion = nil
            }.id(draft.id)
        } else { selectedGraphInspector }
    }
    @ViewBuilder private var selectedGraphInspector: some View {
        switch selection {
        case .note(let id), .discussion(let id):
            if let annotation = reader.graphAnnotations.first(where: { $0.id == id }) {
                BookGraphNoteInspector(reader:reader,original:annotation,palette:palette,includeFuture:includeFuture,
                    compact:directCanvas || (readingCompanion && !companionNoteExpanded),nodeMode:directCanvas,
                    initialDiscussion:directCanvas ? selection == .discussion(id) : nil,
                    toggleExpansion:readingCompanion && !directCanvas ? {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration:0.22)) { companionNoteExpanded.toggle() }
                    } : nil,
                    initialFocusAllowed:!searchVisible && (!readingCompanion || noteInputReady),
                    connect:directCanvas || readingCompanion ? { navigate(.newConnection($0)) } : nil,
                    select:navigate).id(directCanvas ? (canvasFocusedToken ?? id) : id)
            } else if let note = reader.currentPageNotes.first(where: { $0.id.uuidString == id }) {
                BookGraphInkInspector(reader:reader,original:note,palette:palette,nodeMenu:directCanvas ? showExpandedNodeMenu : nil,revealSource:{
                        if readingCompanion { reader.knowledgeCanvasExpanded = false }
                        else { onClose() }
                    },discuss:directCanvas ? nil : { showDiscussion(reader.beginReadingNodeDiscussion(.init(.ink,id))) },
                    resumeWriting:directCanvas ? {
                        #if os(iOS)
                        closeCanvasEditor(); reader.resumePageHandwriting(note)
                        #endif
                    } : nil).id(id)
            } else { chapterInspector }
        case .entity(let id):
            if let entity = index.entities.first(where: { $0.id == id }) {
                BookGraphEntityInspector(reader:reader,original:entity,palette:palette,includeFuture:includeFuture,nodeMode:directCanvas,connect:directCanvas || readingCompanion ? { navigate(.newConnection($0)) } : nil,select:navigate).id(id)
            } else { chapterInspector }
        case .relation(let id):
            if let edge = index.graph.edges.first(where:{ $0.relationship?.id == id && $0.deletedAt == nil }) {
                ReadingConnectionInspector(reader:reader,edge:edge,palette:palette) { if directCanvas { canvasEditing = nil } else { select(.entities) } }.id(id)
            } else { chapterInspector }
        case .connection(let id):
            if let edge = index.graph.edges.first(where:{ $0.id == id && $0.deletedAt == nil }) {
                ReadingConnectionInspector(reader:reader,edge:edge,palette:palette) { if directCanvas { canvasEditing = nil } else { select(.entities) } }.id(id)
            } else { chapterInspector }
        case .newEvent:
            BookGraphEventComposer(reader:reader,palette:palette,close:cancelInlineCreation) { edge in
                creationReturn = nil
                if let bookID = reader.currentID { reader.revealReadingConnection(edge,bookID:bookID) }
                focusRequest = UUID()
            }
        case .newEntity(let kind): BookGraphNewEntity(reader:reader,kind:kind,palette:palette) { value in
            if value == .entities { cancelInlineCreation() }
            else { reader.showNoteGraph = true; reader.selectionEntity = nil; reader.selectionDiscussion = nil; navigate(value) }
        }.id(kind)
        case .newConnection(let source): ReadingNodeLinks(reader:reader,source:source,palette:palette,close:cancelInlineCreation).id(source)
        // Only unfinished drafts from the older editor use its recovery path.
        case .newRelation(let source): BookGraphRelationEditor(reader:reader,original:nil,sourceID:source,palette:palette,includeFuture:includeFuture,select:navigate).id("recovered-\(source?.uuidString ?? "")")
        case .highlights:
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Label("划线摘录",systemImage:"text.quote").font(.title2)
                    Text("点原句查看上下文，也可以随时补充想法。").font(.callout).foregroundStyle(.secondary)
                    ForEach(graphNotes.filter(\.highlightOnly)) { note in Button { navigate(.note(note.id)) } label: { BookReadingNoteRow(note:note) }.buttonStyle(.plain) }
                }.padding(26).frame(maxWidth:.infinity,alignment:.leading)
            }.background(palette.paper)
        case .entities:
            BookGraphThingsLibrary(reader:reader,palette:palette,includeFuture:includeFuture,focusesOnPeople:readingCompanion,select:navigate)
        case .chapter: chapterInspector
        }
    }
    private var chapterInspector: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Label("章节",systemImage:"book").font(.caption).foregroundStyle(.secondary)
                Text(chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].title : nil } ?? "阅读笔记").font(.system(size:27,weight:.medium,design:.serif))
                Text(reviewing ? "回看自己留下的理解与记录。划线已收纳，人物与关系仍在同一张图中。" : "想法、划线和手写，都留在读到的地方。").font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                GraphWrappingLayout {
                    Button("AI 对话",systemImage:"bubble.left.and.bubble.right") {
                        let chapter = chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0] : nil }
                        showDiscussion(reader.beginReadingNodeDiscussion(chapter:chapter))
                    }.disabled(reader.loading || reader.busy)
                    Button { navigate(.newEvent) } label: { Label("添加事件",systemImage:"arrow.triangle.branch") }.buttonStyle(.bordered).disabled(reader.loading || reader.busy)
                    Button { addNote() } label: { Label("添加本小节笔记",systemImage:"square.and.pencil") }
                }.buttonStyle(.bordered)
                if let id = chapterID, index.structure.nodes.indices.contains(id) {
                    let sections = index.structure.nodes.filter { index.structure.ancestors(of:$0.id).contains(id) }
                    if !sections.isEmpty {
                        Divider()
                        Text("本章小节 · \(sections.count)").font(.headline)
                        ForEach(sections) { section in
                            Button { navigate(.chapter(section.id)) } label: {
                                HStack(alignment:.top,spacing:8) {
                                    Image(systemName:"text.alignleft")
                                    Text(section.entry.title).multilineTextAlignment(.leading)
                                    Spacer(minLength:0)
                                    Image(systemName:"arrow.up.left").font(.caption2)
                                }.font(.callout).padding(.vertical,6)
                                    .padding(.leading,CGFloat(min(3,max(0,section.depth-index.structure.nodes[id].depth-1)))*12)
                            }.buttonStyle(.plain).accessibilityLabel("在结构图中查看小节：\(section.entry.title)")
                        }
                    }
                }
                let recent = Array(graphNotes.suffix(8).reversed())
                if !recent.isEmpty {
                    Divider()
                    Text("本小节笔记与摘录").font(.headline)
                    ForEach(recent) { note in
                        Button { navigate(.note(note.id)) } label: {
                            VStack(alignment:.leading,spacing:8) {
                                BookReadingNoteRow(note:note)
                                Label("补充笔记",systemImage:"square.and.pencil").font(.caption).foregroundStyle(palette.accent)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !readingCompanion { Button("查看图中记录") { selection = .entities }.buttonStyle(.borderless) }
                if let id = chapterID, reader.chapters.indices.contains(id) {
                    BookGraphSource(reader:reader,locator:"",href:reader.chapters[id].href,palette:palette)
                }
                if let id = reader.noteUndoID { Button("撤销刚才的删除") { reader.restoreRemovedNote(id) } }
                if reader.noteDraftCount > 0 || !reader.removedNotes.isEmpty { Button("草稿与最近删除") { recovery = true } }
                let removed = (reader.currentBook?.knowledgeRelations ?? []).filter { $0.deletedAt != nil }
                if !removed.isEmpty {
                    DisclosureGroup("已移除的关系（\(removed.count)）") {
                        ForEach(removed) { relation in
                            Button("恢复：\(index.entities.first { $0.id == relation.sourceID }?.name ?? "") → \(relation.label) → \(index.entities.first { $0.id == relation.targetID }?.name ?? "")") {
                                if reader.setRelationDeleted(relation.id,deleted:false) { select(.relation(relation.id)) }
                            }.buttonStyle(.borderless).padding(.vertical,8)
                        }
                    }
                }
            }.padding(26).frame(maxWidth:.infinity,alignment:.leading)
        }.background(palette.paper)
    }
    private func showDiscussion(_ discussion: ReadingNodeID?) {
        guard let target = discussion else { if directCanvas { canvasFailure = reader.error }; return }
        navigate(.discussion(target.owner))
    }
    private func close() {
        guard !closingWorkspace else { return }
        closingWorkspace = true
        let bookID = reader.currentID, session = reader.sessionID
        Task { @MainActor in
            defer { closingWorkspace = false }
            #if os(iOS)
            if let flush = reader.mindMapInputFlush, !(await flush.perform()) { return }
            #endif
            guard reader.currentID == bookID, reader.sessionID == session else { return }
            onClose()
        }
    }
    private func addNote() {
        if directCanvas { addCanvasBranch(from:nil); return }
        finishCompanionSearch()
        reader.selectionDiscussion = nil; reader.selectionEntity = nil; reader.discussionNoteID = nil
        if readingCompanion { reader.showNoteGraph = true }
        if let note = reader.newGraphNote(chapterID:chapterID) {
            selection = .note(note.id); noteLimit = max(noteLimit,graphNotes.count)
        }
    }
    private func selectInitial() {
        // Independent selection editors keep their own draft and lifetime.
        // Projecting them into the map can create a second editor or clear the
        // selection before the form has appeared.
        if directCanvas, selectedDiscussionDraft != nil || selectedEntityDraft != nil { return }
        if readingCompanion, let draft = selectedEntityDraft,
           let note = index.notes.first(where:{ $0.id == draft.annotation.id }) {
            selection = .note(note.id); chapterID = note.chapterID
            chapterSource = note.chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].href : nil }
            focusRequest = UUID(); return
        }
        chapterID = readingChapter ?? reader.chapters.indices.first
        if let item = reader.selectedReadingItem { applyReadingSelection(item) }
        else if let id = reader.graphNoteID ?? reader.annotationDraft?.id, index.notes.contains(where: { $0.id == id }) { select(reader.discussionNoteID == id ? .discussion(id) : .note(id)) }
        else { select(.chapter(chapterID)) }
        if directCanvas {
            if case .discussion = selection { canvasEditing = selection }
            else if reader.annotationDraft != nil { canvasCommand = .init(name:"edit",target:canvasFocusedToken) }
        }
        focusRequest = UUID()
    }
    private func select(_ value: BookGraphSelection) {
        if readingCompanion && value == .entities {
            if let id = reader.graphNoteID, index.notes.contains(where:{ $0.id == id }) { select(.note(id)) }
            else { select(.chapter(chapterID)) }
            return
        }
        selection = value; noteLimit = 6
        switch value {
        case .chapter(let id):
            chapterID = id
            chapterSource = id.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0].href : nil }
        case .note(let id), .discussion(let id):
            if let note = index.notes.first(where: { $0.id == id }) { chapterID = note.chapterID; noteLimit = max(6,(index.notes(in:chapterID).firstIndex(where: { $0.id == id }) ?? 0)+1) }
        case .entity,.relation,.connection,.newEvent,.newEntity,.newConnection,.newRelation,.highlights,.entities: break
        }
        let item: ReadingGraphSelection?
        switch value {
        case .note(let id): item = .node(.init(reader.currentPageNotes.contains(where:{ $0.id.uuidString==id }) ? .ink : .note,id))
        case .discussion(let id): item = .node(.init(.discussion,id))
        case .entity(let id): item = .node(.init(.entity,id.uuidString))
        case .relation(let id): item = index.graph.edges.first(where:{ $0.relationship?.id == id }).map { .edge($0.id) }
        case .connection(let id): item = .edge(id)
        default: item = nil
        }
        if let item { reader.selectReadingItem(item) }
        else if case .chapter = value {
            reader.selectedReadingItem = nil; reader.discussionNoteID = nil; reader.discussionFocusMessage = nil
            reader.graphNoteID = nil; reader.annotationDraft = nil
        }
    }
    private func applyReadingSelection(_ item: ReadingGraphSelection) {
        // Rendering is a typed view of the shared selection, including message
        // and source nodes which open their owning editor without losing focus.
        switch item {
        case .node(let id):
            switch id.kind {
            case .entity: if let uuid = UUID(uuidString:id.owner) { selection = .entity(uuid) }
            case .discussion, .message: selection = .discussion(id.owner)
            case .source: selection = id.local == "excerpt" ? .note(id.owner) : .discussion(id.owner)
            case .note, .ink: selection = .note(id.owner)
            }
            if let note = index.notes.first(where:{ $0.id == id.owner }) {
                chapterID = note.chapterID; noteLimit = max(6,(index.notes(in:chapterID).firstIndex(where:{ $0.id == note.id }) ?? 0)+1)
            }
        case .edge(let id):
            if let relation = index.graph.edges.first(where:{ $0.id == id })?.relationship { selection = .relation(relation.id) }
            else { selection = .connection(id) }
            let owner = id.source.kind == .entity ? id.target.owner : id.source.owner
            if let note = index.notes.first(where:{ $0.id == owner }) { chapterID = note.chapterID }
        }
    }
    private func navigate(_ value: BookGraphSelection) {
        if directCanvas {
            switch value {
            case .newConnection(let source): beginCanvasConnection(source); return
            case .newEvent: beginCanvasConnection(connectionSource); return
            case .newEntity: addCanvasBranch(from:nil); return
            case .note, .discussion, .entity, .relation, .connection:
                select(value); canvasEditing = value; focusRequest = UUID(); return
            case .chapter:
                canvasEditing = nil; select(value); focusRequest = UUID(); return
            case .entities:
                canvasEditing = nil; canvasCommand = .init(name:"center"); return
            default: break
            }
        }
        if case .newEntity = value { addNote(); return }
        switch value {
        case .newEvent, .newEntity, .newConnection:
            if readingCompanion {
                creationReturn = selection
                select(value)
                return
            }
            guard let bookID = reader.currentID else { return }
            creationResult = nil
            creation = BookGraphCreation(bookID:bookID,selection:value)
            return
        default: break
        }
        select(value); focusRequest = UUID()
    }
    private func cancelInlineCreation() {
        let previous = creationReturn ?? .chapter(chapterID)
        creationReturn = nil
        select(previous)
    }
    private func finishCreation() {
        guard let result = creationResult else { return }
        creationResult = nil
        guard reader.currentID == result.bookID else { return }
        if case .edge(let id) = result.item { reader.revealReadingConnection(id,bookID:result.bookID) }
        else { reader.selectReadingItem(result.item) }
        focusRequest = UUID()
    }
}



private extension BookNotesWorkspace {
    var directGraph: some View {
        ZStack(alignment:.bottom) {
            GeometryReader { geometry in
                #if os(iOS)
                let document = reader.mindMapDocument(includeFuture:includeFuture)
                let focusedToken = focusedCanvasToken(in:document)
                let leftSpace = max(0,(canvasTopicRect?.minX ?? 0)-24)
                let rightSpace = max(0,geometry.size.width-(canvasTopicRect?.maxX ?? 0)-24)
                let editorWidth = min(360,max(240,min(geometry.size.width*0.44,max(leftSpace,rightSpace))))
                let editorHeight = min(380,max(150,geometry.size.height*0.44))
                let editorRect = CGRect(x:leftSpace > rightSpace ? 12 : max(8,geometry.size.width-editorWidth-12),y:readingCompanion ? 76 : 12,width:editorWidth,height:editorHeight)
                ZStack(alignment:.topLeading) {
                    MindMapCanvas(reader:reader,document:document,includeFuture:includeFuture,editor:canvasEditing != nil,
                        expandedNode:canvasExpandsNode ? focusedToken : nil,
                        expandedSize:CGSize(width:min(440,max(200,geometry.size.width-24)),height:min(canvasContentHeightLimit,max(80,geometry.size.height-220))),enabled:noteInputReady && !focusedTranslation,
                        focus:focusedToken,focusRequest:focusRequest,command:canvasCommand,
                        selected:{ token,rect in canvasTopicRect = rect; selectCanvasTopic(token,rect:rect,document:document) },
                        action:{ action,token,rect in performCanvasAction(action,token:token,rect:rect,document:document) },
                        edgeSelected:{ edge in select(.connection(edge)); canvasEditing = .connection(edge) },
                        frameChanged:{ token,rect in
                            if canvasEditing != nil, token == focusedToken, canvasTopicRect != rect { canvasTopicRect = rect }
                        },contentFrameChanged:{ token,rect in
                            if canvasExpandsNode, token == focusedToken, canvasContentRect != rect { canvasContentRect = rect }
                        },failed:{ canvasFailure = $0 })
                        .id(reader.currentID).accessibilityIdentifier("direct-graph-canvas")
                        .accessibilityHidden(focusedTranslation)
                    if readingCompanion && (selectedDiscussionDraft != nil || selectedEntityDraft != nil) {
                        inspector
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                            .padding(.top,focusedTranslation ? 0 : 64)
                    } else if canvasExpandsNode, let rect=canvasContentRect {
                        canvasEditor.frame(width:rect.width,height:rect.height)
                            .offset(x:rect.minX,y:rect.minY)
                    } else if canvasEditing != nil && !canvasExpandsNode {
                        canvasEditor.frame(width:editorRect.width,height:editorRect.height)
                            .offset(x:editorRect.minX,y:editorRect.minY)
                    }
                }.clipped()
                .overlayPreferenceValue(CanvasEditorSave.self) { save in
                    if let topic = actionTopic, noteInputReady && !focusedTranslation {
                        NodeMenuPlacement(anchor:actionAnchor,hasTopToolbar:readingCompanion) {
                            CanvasNodeActions(topic:topic,palette:palette) { name in
                                guard save?() != false else { actionTopic = nil; return }
                                actionTopic = nil
                                if name == "add" || name == "connect" { closeCanvasEditor() }
                                canvasCommand = .init(name:name,target:topic.id)
                            }.id(topic.id).disabled(reader.loading)
                                .accessibilityAction(.escape) { actionTopic = nil }
                        }
                    }
                }
                .onChange(of:reader.currentID) { _ in actionTopic = nil }
                .onChange(of:geometry.size) { _ in actionTopic = nil }
                .onChange(of:canvasCommand?.id) { _ in actionTopic = nil }
                .onChange(of:canvasLinksToken) { _ in canvasLinkDetail = nil }
                .onChange(of:canvasExpandsNode ? focusedToken : nil) { _ in
                    canvasContentRect = nil
                    canvasNoteContentHeight = nil
                }
                #else
                graphCanvas(viewport:geometry.size)
                #endif
            }
            if !focusedTranslation { VStack(spacing:4) {
            HStack(spacing:8) {
            HStack(spacing:0) {
                Button { canvasCommand = .init(name:"undo") } label: { Image(systemName:"arrow.uturn.backward").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("撤销导图操作")
                Button { canvasCommand = .init(name:"redo") } label: { Image(systemName:"arrow.uturn.forward").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("重做导图操作")
            }.padding(.horizontal,4).modifier(BookNotesGlassSurface(palette:palette,shape:Capsule()))
                Spacer(minLength:4)
            HStack(spacing:0) {
                Button { canvasCommand = .init(name:"zoomOut") } label: { Image(systemName:"minus.magnifyingglass").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("缩小结构图")
                Button { canvasCommand = .init(name:"center") } label: { Image(systemName:"viewfinder").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("查看整张结构图")
                Button { canvasCommand = .init(name:"zoomIn") } label: { Image(systemName:"plus.magnifyingglass").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("放大结构图")
            }.padding(.horizontal,4).modifier(BookNotesGlassSurface(palette:palette,shape:Capsule()))
            }.buttonStyle(.plain)
            if let canvasFailure {
                HStack {
                    Text(canvasFailure).font(.caption).foregroundStyle(.red)
                    Button("重试保存") { canvasCommand = .init(name:"retry"); self.canvasFailure = nil }.frame(minWidth:60,minHeight:44)
                }.padding(.horizontal,12)
            }
            }.padding(.horizontal,12).padding(.bottom,12) }
        }.background(palette.background)
    }
    var canvasFocusedToken: String? { focusedCanvasToken(in:reader.mindMapDocument(includeFuture:includeFuture)) }
    func focusedCanvasToken(in document: MindMapDocument) -> String? {
        switch selection {
        case .chapter(let id):
            guard let id else { return document.nodeData.id }
            return (try? document.flattened())?.first { $0.topic.metadata?.kind == "chapter" && $0.topic.metadata?.chapterID == id }?.topic.id
        case .note(let id), .discussion(let id):
            let kind: ReadingNodeID.Kind = selection == .discussion(id) ? .discussion :
                (reader.currentPageNotes.contains(where:{ $0.id.uuidString == id }) ? .ink : .note)
            let node = ReadingNodeID(kind,id)
            return document.topic(containing:node)?.id ?? reader.mindMapToken(node)
        case .entity(let id): return reader.mindMapToken(.init(.entity,id.uuidString))
        default: return nil
        }
    }
    var canvasExpandsNode: Bool {
        guard let canvasEditing else { return false }
        switch canvasEditing {
        case .note,.discussion,.entity: return true
        default: return false
        }
    }
    var canvasContentHeightLimit: CGFloat {
        if canvasLinksToken != nil, canvasLinkDetail != nil { return 320 }
        if canvasLinksToken == nil, case .discussion = canvasEditing { return 440 }
        if let height = canvasNoteContentHeight { return min(480,height + 54) }
        if canvasLinksToken != nil { return 148 }
        guard case .note(let id) = canvasEditing else { return 250 }
        return reader.currentPageNotes.contains(where:{ $0.id.uuidString == id }) ? 440 : 132
    }
    func selectCanvasTopic(_ token: String,rect: CGRect?,document: MindMapDocument) {
        if canvasExpandsNode, token == canvasFocusedToken { return }
        guard let topic = try? document.flattened().first(where:{ $0.topic.id == token })?.topic else { return }
        canvasLinksToken = nil
        if let id = topic.metadata?.nodeID {
            let value: BookGraphSelection
            switch id.kind {
            case .entity: guard let uuid = UUID(uuidString:id.owner) else { return }; value = .entity(uuid)
            case .discussion: value = .discussion(id.owner)
            default: value = .note(id.owner)
            }
            if selection != value { canvasEditing = nil; select(value) }
        } else if topic.metadata?.kind == "book" || topic.metadata?.kind == "chapter" {
            let value = BookGraphSelection.chapter(topic.metadata?.chapterID)
            if selection != value { canvasEditing = nil; select(value) }
        }
    }
    func showExpandedNodeMenu() {
        guard canvasExpandsNode, let token = canvasFocusedToken else { return }
        canvasCommand = .init(name:"menu",target:token)
    }
    func performCanvasAction(_ action: String,token: String,rect: CGRect?,document: MindMapDocument) {
        if action == "closeMenu" { actionTopic = nil; return }
        if action == "menu", let rect,
           let topic = try? document.flattened().first(where:{ $0.topic.id == token })?.topic {
            actionAnchor = rect; actionTopic = topic
            return
        }
        actionTopic = nil
        if action == "collapse" { closeCanvasEditor(); return }
        if action == "dismiss" { canvasLinksToken = nil; canvasEditing = nil; return }
        if action == "deselect" {
            if canvasEditing != nil { closeCanvasEditor() }
            canvasTopicRect = nil
            select(.chapter(chapterID))
            return
        }
        selectCanvasTopic(token,rect:rect,document:document)
        guard let topic = try? reader.mindMapDocument(includeFuture:includeFuture).flattened().first(where:{ $0.topic.id == token })?.topic else { return }
        if action == "ai" { openCanvasDiscussion(topic); return }
        if action == "content" { openCanvasContent(topic); return }
        if action == "note" {
            if canvasExpandsNode && canvasFocusedToken == token { closeCanvasEditor() }
            else { openCanvasContent(topic) }
        }
    }
    func openCanvasDiscussion(_ topic: MindMapTopic) {
        canvasLinksToken = nil
        if let id = topic.metadata?.nodeID { showDiscussion(reader.beginReadingNodeDiscussion(id)) }
        else {
            let chapter = topic.metadata?.chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0] : nil }
            showDiscussion(reader.beginReadingNodeDiscussion(chapter:chapter))
        }
    }
    func openCanvasContent(_ topic: MindMapTopic) {
        canvasLinksToken = nil
        var node = topic.metadata?.nodeID
        if node == nil {
            node = topic.metadata?.attachedNodes?.first { $0.kind == .note }
            if node == nil {
                let chapter = topic.metadata?.chapterID.flatMap { reader.chapters.indices.contains($0) ? reader.chapters[$0] : nil }
                if let thread = reader.beginReadingNodeDiscussion(chapter:chapter) { node = .init(.note,thread.owner) }
            }
        }
        guard let node else { canvasFailure = reader.error; return }
        let value: BookGraphSelection
        if node.kind == .entity, let id = UUID(uuidString:node.owner) { value = .entity(id) }
        else { value = .note(node.owner) }
        select(value)
        canvasEditing = value
    }
    func closeCanvasEditor() {
        canvasLinksToken = nil
        canvasEditing = nil
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)
        #endif
    }
    func beginCanvasConnection(_ source: ReadingNodeID?) {
        canvasEditing = nil
        canvasCommand = .init(name:"connect",target:source.map { reader.mindMapToken($0) })
    }
    func addCanvasBranch(from source: ReadingNodeID?) {
        finishCompanionSearch()
        reader.showNoteGraph = true; reader.selectionDiscussion = nil; reader.selectionEntity = nil; reader.annotationDraft = nil
        canvasEditing = nil
        canvasCommand = .init(name:source == nil ? "addRoot" : "add",target:source.map { reader.mindMapToken($0) })
    }
    @ViewBuilder var canvasEditor: some View {
        if canvasExpandsNode {
            let document = reader.mindMapDocument(includeFuture:includeFuture)
            let token = focusedCanvasToken(in:document)
            let topic = try? document.flattened().first { $0.topic.id == token }?.topic
            Group {
                if let topic, canvasLinksToken == topic.id {
                    if let id = canvasLinkDetail, let edge = reader.currentBook?.graph.edges.first(where:{ $0.id == id && $0.deletedAt == nil }) {
                        ReadingConnectionInspector(reader:reader,edge:edge,palette:palette,openEndpoint:{ endpoint in
                            if let next = document.topic(containing:endpoint) {
                                openCanvasContent(next)
                                focusRequest = UUID()
                            }
                        }) { canvasLinkDetail = nil }.id(id)
                    } else { canvasLinks(topic,document:document) }
                }
                else { inspector }
            }
            .padding(.top,50)
            .overlayPreferenceValue(CanvasEditorSave.self) { save in
                if let topic {
                    VStack(spacing:0) {
                        HStack(spacing:2) {
                            canvasTab("笔记",active:canvasLinksToken == nil && !canvasDiscussing) {
                                if save?() != false { openCanvasContent(topic) }
                            }
                            canvasTab("连接",active:canvasLinksToken == topic.id) {
                                if save?() != false { canvasLinksToken = topic.id }
                            }
                            canvasTab("AI",active:canvasLinksToken == nil && canvasDiscussing) {
                                if save?() != false { openCanvasDiscussion(topic) }
                            }
                        }
                        .padding(.horizontal,2)
                        .background(palette.field,in:RoundedRectangle(cornerRadius:12))
                        Spacer(minLength:0)
                    }
                }
            }
            .clipShape(Rectangle())
                .onPreferenceChange(GraphCardContentHeight.self) { height in
                    if height > 0 && canvasNoteContentHeight != height { canvasNoteContentHeight = height }
                }
                .accessibilityElement(children:.contain)
                .accessibilityIdentifier("graph-inline-editor")
        } else { floatingCanvasEditor }
    }
    var canvasDiscussing: Bool {
        if case .discussion = canvasEditing { return true }
        return false
    }
    func canvasTab(_ title: String,active: Bool,action: @escaping () -> Void) -> some View {
        Button { if !active { action() } } label: {
            Text(title).font(.subheadline.weight(active ? .semibold : .regular))
                .frame(maxWidth:.infinity,minHeight:36)
                .foregroundStyle(active ? palette.canvasAccent : palette.muted)
                .background { if active { RoundedRectangle(cornerRadius:9).fill(palette.paper) } }
                .frame(minHeight:44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }
    func canvasLinks(_ topic: MindMapTopic,document: MindMapDocument) -> some View {
        let connections = document.arrows.filter { $0.from == topic.id || $0.to == topic.id }
        let rows = (try? document.flattened()) ?? []
        return ScrollView {
            VStack(alignment:.leading,spacing:10) {
                ForEach(connections,id:\.id) { arrow in
                    if let edge = arrow.edgeID {
                        let other = arrow.from == topic.id ? arrow.to : arrow.from
                        Button { canvasLinkDetail = edge } label: {
                            HStack(spacing:10) {
                                Image(systemName:arrow.from == topic.id ? "arrow.up.right" : "arrow.down.left").foregroundStyle(palette.muted)
                                VStack(alignment:.leading,spacing:4) {
                                    let target = rows.first { $0.topic.id == other }?.topic
                                    Text(target?.metadata?.name ?? target?.topic ?? "").font(.body).lineLimit(2)
                                    Text(arrow.label).font(.caption).foregroundStyle(palette.muted)
                                }
                                Spacer(minLength:0)
                                Image(systemName:"chevron.right").font(.caption).foregroundStyle(palette.muted)
                            }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Button("添加连接",systemImage:"link") {
                    closeCanvasEditor()
                    canvasCommand = .init(name:"connect",target:topic.id)
                }.buttonStyle(.bordered)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
                .modifier(GraphCardContentSize(enabled:true))
        }
    }
    var floatingCanvasEditor: some View {
        VStack(spacing:0) {
            HStack {
                Label(selection == .discussion(activeNote?.id ?? "") ? "AI 对话" : activeNote?.ink == true ? "手写标记" : "节点内容",systemImage:"square.and.pencil").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成",action:closeCanvasEditor)
                    .frame(minWidth:54,minHeight:44).accessibilityLabel("完成节点编辑")
            }.padding(.horizontal,14)
            Divider()
            inspector
        }.clipShape(RoundedRectangle(cornerRadius:20))
            .modifier(BookNotesGlassSurface(palette:palette,shape:RoundedRectangle(cornerRadius:20)))
            .accessibilityElement(children:.contain)
            .accessibilityIdentifier("graph-inline-editor")
    }
}

private struct BookNotesGlassSurface<S: Shape>: ViewModifier {
    let palette: BookGraphPalette
    let shape: S
    var active = true
    @ViewBuilder func body(content: Content) -> some View {
        if active, palette.themeColors != nil {
            content.background(palette.paper,in:shape)
                .overlay(shape.stroke(palette.line,lineWidth:0.65).allowsHitTesting(false))
                .shadow(color:.black.opacity(0.06),radius:5,y:2)
        } else if active {
            #if os(iOS)
            content.modifier(ReaderGlassSurface(shape:shape))
            #else
            content.background(.regularMaterial,in:shape)
            #endif
        } else { content }
    }
}

private struct BookGraphLine {
    let path: CGPath
    let accent: Bool
    let width: CGFloat
}

private struct BookGraphConnections: View {
    let lines: [BookGraphLine]
    let scale: Double
    let palette: BookGraphPalette
    var body: some View {
        #if os(iOS)
        BookGraphLineLayers(lines:lines,scale:scale,palette:palette)
        #else
        Canvas { context,_ in
            context.scaleBy(x:scale,y:scale)
            for line in lines {
                context.stroke(Path(line.path),with:.color(line.accent ? palette.accent : palette.ink.opacity(palette.dark ? 0.36 : 0.28)),lineWidth:line.width)
            }
        }
        #endif
    }
}

#if os(iOS)
private struct BookGraphLineLayers: UIViewRepresentable {
    let lines: [BookGraphLine]
    let scale: Double
    let palette: BookGraphPalette
    func makeUIView(context: Context) -> BookGraphLineView { BookGraphLineView() }
    func updateUIView(_ view: BookGraphLineView,context: Context) {
        let traits = UITraitCollection(userInterfaceStyle:palette.dark ? .dark : .light)
        view.update(lines:lines,scale:scale,normal:UIColor(palette.ink.opacity(palette.dark ? 0.36 : 0.28)).resolvedColor(with:traits).cgColor,accent:UIColor(palette.accent).resolvedColor(with:traits).cgColor)
    }
}

/// Render only a bounded visible region. UIKit stays on the main thread, and
/// vector layers avoid both background UIView drawing and a canvas-sized bitmap.
private final class BookGraphLineView: UIView {
    private struct Style: Hashable { let accent: Bool; let width: CGFloat }
    private var lines: [BookGraphLine] = []
    private var scale: CGFloat = 1
    private var normal: CGColor = UIColor.clear.cgColor
    private var accent: CGColor = UIColor.clear.cgColor
    private var strokes: [Style:CAShapeLayer] = [:]
    private var region = CGRect.null
    private var dirty = true
    private var scrollObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    override init(frame: CGRect) {
        super.init(frame:frame)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        accessibilityIdentifier = "book-graph-connections"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        scrollObservation = nil; boundsObservation = nil
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                scrollObservation = scroll.observe(\.contentOffset) { [weak self] _,_ in
                    DispatchQueue.main.async { self?.setNeedsLayout() }
                }
                boundsObservation = scroll.observe(\.bounds) { [weak self] _,_ in
                    DispatchQueue.main.async { self?.setNeedsLayout() }
                }
                break
            }
            ancestor = view.superview
        }
        setNeedsLayout()
    }
    func update(lines: [BookGraphLine],scale: Double,normal: CGColor,accent: CGColor) {
        self.lines = lines; self.scale = scale; self.normal = normal; self.accent = accent
        dirty = true; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, scale.isFinite, scale > 0 else { return }
        var visible = bounds.intersection(convert(window.bounds,from:window))
        var ancestor = superview
        while let view = ancestor, view !== window {
            if view.clipsToBounds { visible = visible.intersection(convert(view.bounds,from:view)) }
            ancestor = view.superview
        }
        guard !visible.isNull, !visible.isEmpty else { return }
        // Quantization avoids rebuilding paths on every pixel of a pan. The
        // region remains bounded by the actual viewport plus a small lookahead.
        let step: CGFloat = 512
        let target = visible.insetBy(dx:-128,dy:-128).intersection(bounds)
        let left = floor(target.minX/step)*step, top = floor(target.minY/step)*step
        let next = CGRect(x:left,y:top,width:ceil(target.maxX/step)*step-left,height:ceil(target.maxY/step)*step-top)
        guard dirty || next != region else { return }
        dirty = false; region = next
        let transform = CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:-next.minX,ty:-next.minY)
        let scaling = CGAffineTransform(scaleX:scale,y:scale)
        var paths: [Style:CGMutablePath] = [:]
        for line in lines where line.path.boundingBoxOfPath.applying(scaling).insetBy(dx:-8,dy:-8).intersects(next) {
            let style = Style(accent:line.accent,width:line.width)
            let path = paths[style] ?? CGMutablePath()
            path.addPath(line.path,transform:transform); paths[style] = path
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for style in Array(strokes.keys) where paths[style] == nil {
            strokes.removeValue(forKey:style)?.removeFromSuperlayer()
        }
        for (style,path) in paths {
            let stroke = strokes[style] ?? CAShapeLayer()
            if stroke.superlayer == nil { layer.addSublayer(stroke); strokes[style] = stroke }
            stroke.frame = next; stroke.path = path
            stroke.fillColor = nil; stroke.strokeColor = style.accent ? accent : normal
            stroke.lineWidth = style.width*scale; stroke.masksToBounds = true
            stroke.contentsScale = traitCollection.displayScale
        }
        CATransaction.commit()
    }
}

#endif

private struct BookNodeScale: ViewModifier {
    let width: Double
    let height: Double
    let scale: Double
    func body(content: Content) -> some View {
        content.frame(width:width,height:height).scaleEffect(scale,anchor:.topLeading).frame(width:width*scale,height:height*scale,alignment:.topLeading)
    }
}

private struct BookNoteNodeLayout: Layout {
    let positions: [CGRect]
    let size: CGSize
    let scale: Double
    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize { CGSize(width:size.width*scale,height:size.height*scale) }
    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) {
        for (index,view) in subviews.enumerated() where positions.indices.contains(index) {
            let rect = positions[index]
            view.place(at:CGPoint(x:bounds.minX+rect.minX*scale,y:bounds.minY+rect.minY*scale),anchor:.topLeading,proposal:ProposedViewSize(width:rect.width*scale,height:rect.height*scale))
        }
    }
}

/// The graph owns a two-axis viewport, separate from the inspector's scrolling.
/// Content updates preserve its origin; only explicit navigation requests focus.
enum BookGraphViewportPosition {
    static func overviewScale(canvas: CGSize,viewport: CGSize) -> CGFloat {
        min(1,max(1,viewport.width-32)/max(1,canvas.width),max(1,viewport.height-32)/max(1,canvas.height))
    }
    static func clamp(_ origin: CGPoint, canvas: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x:min(max(0,origin.x),max(0,canvas.width-viewport.width)),
                y:min(max(0,origin.y),max(0,canvas.height-viewport.height)))
    }
    static func centered(on point: CGPoint, canvas: CGSize, viewport: CGSize) -> CGPoint {
        clamp(CGPoint(x:point.x-viewport.width/2,y:point.y-viewport.height/2),canvas:canvas,viewport:viewport)
    }
}

struct BookGraphCurve {
    let path: CGPath
    let points: [CGPoint]
}

/// Prefer a single soft curve between cards. Obstacle routing is a fallback;
/// captions sit over the finished wire rather than becoming routing obstacles.
enum BookGraphRouting {
    static let clearance: CGFloat = 12
    static func connection(from source: CGRect,to target: CGRect,obstacles: [CGRect]) -> BookGraphCurve {
        let dx = target.midX-source.midX, dy = target.midY-source.midY
        let horizontal = (CGPoint(x:dx >= 0 ? source.maxX : source.minX,y:source.midY),CGPoint(x:dx >= 0 ? target.minX : target.maxX,y:target.midY),CGPoint(x:dx >= 0 ? 1 : -1,y:0))
        let vertical = (CGPoint(x:source.midX,y:dy >= 0 ? source.maxY : source.minY),CGPoint(x:target.midX,y:dy >= 0 ? target.minY : target.maxY),CGPoint(x:0,y:dy >= 0 ? 1 : -1))
        let pairs = abs(dx) > abs(dy) ? [horizontal,vertical] : [vertical,horizontal]
        let blocks = obstacles.filter { $0 != source && $0 != target }.map { $0.insetBy(dx:-6,dy:-6) }
        for (start,end,normal) in pairs {
            let gap = (end.x-start.x)*normal.x+(end.y-start.y)*normal.y
            guard gap > 0 else { continue }
            let bend = min(120,max(24,gap*0.5))
            let a = CGPoint(x:start.x+normal.x*bend,y:start.y+normal.y*bend)
            let b = CGPoint(x:end.x-normal.x*bend,y:end.y-normal.y*bend)
            let points = (0...64).map { i -> CGPoint in
                let t = CGFloat(i)/64, u = 1-t
                return CGPoint(x:u*u*u*start.x+3*u*u*t*a.x+3*u*t*t*b.x+t*t*t*end.x,
                               y:u*u*u*start.y+3*u*u*t*a.y+3*u*t*t*b.y+t*t*t*end.y)
            }
            guard !points.contains(where:{ p in blocks.contains { $0.contains(p) } }) else { continue }
            let path = CGMutablePath(); path.move(to:start); path.addCurve(to:end,control1:a,control2:b)
            return .init(path:path,points:points)
        }
        let route = route(from:source,to:target,obstacles:obstacles)
        var points: [CGPoint] = []
        for (a,b) in zip(route,route.dropFirst()) {
            for i in 0..<16 {
                let t = CGFloat(i)/16
                points.append(CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
            }
        }
        if let last = route.last { points.append(last) }
        return .init(path:path(route),points:points)
    }
    static func label(on curve: BookGraphCurve,obstacles: [CGRect]) -> CGRect {
        let points = curve.points, middle = points.count/2
        let order = points.indices.dropFirst().dropLast().sorted { abs($0-middle) < abs($1-middle) }
        for offset in [CGFloat(0),22,-22,44,-44,88,-88,132,-132] {
            for i in order {
                let a = points[i-1], b = points[i+1], length = max(1,hypot(b.x-a.x,b.y-a.y))
                let p = CGPoint(x:points[i].x-(b.y-a.y)/length*offset,y:points[i].y+(b.x-a.x)/length*offset)
                let rect = CGRect(x:p.x-55,y:p.y-22,width:110,height:44)
                if rect.minX >= 12, rect.minY >= 12, !obstacles.contains(where:{ $0.insetBy(dx:-6,dy:-6).intersects(rect) }) { return rect }
            }
        }
        let p = points.isEmpty ? CGPoint(x:80,y:80) : points[middle]
        return CGRect(x:p.x-55,y:p.y-22,width:110,height:44)
    }
    static func crosses(_ a: CGPoint,_ b: CGPoint,rect: CGRect) -> Bool {
        let epsilon: CGFloat = 0.01
        if abs(a.y-b.y) < epsilon {
            return a.y > rect.minY+epsilon && a.y < rect.maxY-epsilon && max(a.x,b.x) > rect.minX+epsilon && min(a.x,b.x) < rect.maxX-epsilon
        }
        return a.x > rect.minX+epsilon && a.x < rect.maxX-epsilon && max(a.y,b.y) > rect.minY+epsilon && min(a.y,b.y) < rect.maxY-epsilon
    }
    static func label(between source: CGRect,and target: CGRect,obstacles: [CGRect]) -> CGRect {
        let width: CGFloat = 110, height: CGFloat = 70
        let middle = CGPoint(x:(source.midX+target.midX)/2,y:(source.midY+target.midY)/2)
        var xs = [middle.x,source.midX,target.midX,min(source.minX,target.minX)-width/2-24,max(source.maxX,target.maxX)+width/2+24,(obstacles.map(\.maxX).max() ?? 0)+width/2+24]
        var ys = (-8...8).map { middle.y+CGFloat($0)*(height+16) }
        if source.maxY < target.minY { ys.append((source.maxY+target.minY)/2) }
        if target.maxY < source.minY { ys.append((target.maxY+source.minY)/2) }
        if source.maxX < target.minX { xs.append((source.maxX+target.minX)/2) }
        if target.maxX < source.minX { xs.append((target.maxX+source.minX)/2) }
        var best: (CGRect,CGFloat)?
        for y in ys {
            for x in xs {
                let rect = CGRect(x:x-width/2,y:y-height/2,width:width,height:height)
                guard rect.minX >= 24, rect.minY >= 24, !obstacles.contains(where:{ $0.insetBy(dx:-10,dy:-10).intersects(rect) }) else { continue }
                let score = abs(x-middle.x)+abs(y-middle.y)
                if best == nil || score < best!.1 { best = (rect,score) }
            }
        }
        return best?.0 ?? CGRect(x:(obstacles.map(\.maxX).max() ?? 0)+24,y:max(24,middle.y-height/2),width:width,height:height)
    }
    static func route(from source: CGRect,to target: CGRect,obstacles: [CGRect],existing: [[CGPoint]] = []) -> [CGPoint] {
        guard source != target else { return [] }
        let region = source.union(target).insetBy(dx:-180,dy:-180)
        let blocks = (obstacles.filter { $0.intersects(region) }+[source,target]).map { $0.insetBy(dx:-clearance,dy:-clearance) }
        func ports(_ r: CGRect) -> [(point:CGPoint,outer:CGPoint,axis:Int)] {
            var result: [(CGPoint,CGPoint,Int)] = [(CGPoint(x:r.minX,y:r.midY),CGPoint(x:r.minX-clearance,y:r.midY),1),
             (CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.maxX+clearance,y:r.midY),1),
             (CGPoint(x:r.midX,y:r.minY),CGPoint(x:r.midX,y:r.minY-clearance),2),
             (CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.midX,y:r.maxY+clearance),2)]
            for fraction in [CGFloat(0.25),CGFloat(0.75)] {
                let x = r.minX+r.width*fraction, y = r.minY+r.height*fraction
                result += [(CGPoint(x:r.minX,y:y),CGPoint(x:r.minX-clearance,y:y),1),(CGPoint(x:r.maxX,y:y),CGPoint(x:r.maxX+clearance,y:y),1),
                           (CGPoint(x:x,y:r.minY),CGPoint(x:x,y:r.minY-clearance),2),(CGPoint(x:x,y:r.maxY),CGPoint(x:x,y:r.maxY+clearance),2)]
            }
            return result
        }
        let starts = ports(source), ends = ports(target)
        let bounds = blocks.reduce(CGRect.null) { $0.union($1) }
        let segments = existing.flatMap { Array(zip($0,$0.dropFirst())) }.filter { CGRect(x:min($0.0.x,$0.1.x),y:min($0.0.y,$0.1.y),width:max(1,abs($0.0.x-$0.1.x)),height:max(1,abs($0.0.y-$0.1.y))).intersects(region) }
        let lanesX = segments.filter { $0.0.x == $0.1.x }.flatMap { [$0.0.x-8,$0.0.x+8] }
        let lanesY = segments.filter { $0.0.y == $0.1.y }.flatMap { [$0.0.y-8,$0.0.y+8] }
        let xs = Array(Set(blocks.flatMap { [$0.minX,$0.maxX] }+(starts+ends).map { $0.outer.x }+lanesX+[max(0,bounds.minX-24),bounds.maxX+24])).sorted()
        let ys = Array(Set(blocks.flatMap { [$0.minY,$0.maxY] }+(starts+ends).map { $0.outer.y }+lanesY+[max(0,bounds.minY-24),bounds.maxY+24])).sorted()
        let width = xs.count, count = width*ys.count
        func point(_ index: Int) -> CGPoint { CGPoint(x:xs[index%width],y:ys[index/width]) }
        func index(_ p: CGPoint) -> Int { ys.firstIndex(of:p.y)!*width+xs.firstIndex(of:p.x)! }
        let allowed = (0..<count).map { i -> Bool in
            let p = point(i)
            return p.x >= 0 && p.y >= 0 && !blocks.contains { p.x > $0.minX+0.01 && p.x < $0.maxX-0.01 && p.y > $0.minY+0.01 && p.y < $0.maxY-0.01 }
        }
        var neighbors = Array(repeating:[(Int,Int,CGFloat)](),count:count)
        for i in 0..<count where allowed[i] {
            for j in [i%width+1 < width ? i+1 : -1,i+width < count ? i+width : -1] where j >= 0 && allowed[j] {
                let a = point(i), b = point(j)
                guard !blocks.contains(where:{ crosses(a,b,rect:$0) }) else { continue }
                let axis = a.y == b.y ? 1 : 2
                var length = abs(a.x-b.x)+abs(a.y-b.y)
                for (p,q) in segments {
                    if axis == 1 && p.y == q.y && a.y == p.y {
                        length += max(0,min(max(a.x,b.x),max(p.x,q.x))-max(min(a.x,b.x),min(p.x,q.x)))*4
                    } else if axis == 2 && p.x == q.x && a.x == p.x {
                        length += max(0,min(max(a.y,b.y),max(p.y,q.y))-max(min(a.y,b.y),min(p.y,q.y)))*4
                    } else if axis == 1 && p.x == q.x && p.x > min(a.x,b.x) && p.x < max(a.x,b.x) && a.y > min(p.y,q.y) && a.y < max(p.y,q.y) {
                        length += 12
                    } else if axis == 2 && p.y == q.y && p.y > min(a.y,b.y) && p.y < max(a.y,b.y) && a.x > min(p.x,q.x) && a.x < max(p.x,q.x) {
                        length += 12
                    }
                }
                neighbors[i].append((j,axis,length)); neighbors[j].append((i,axis,length))
            }
        }
        var distance = Array(repeating:CGFloat.infinity,count:count*3)
        var parent = Array(repeating:-1,count:count*3), origin = parent
        var queue = Queue()
        for (port,p) in starts.enumerated() where allowed[index(p.outer)] {
            let state = index(p.outer)*3+p.axis
            let penalty: CGFloat = port < 4 ? 0 : 12
            distance[state] = penalty; origin[state] = port; queue.push((penalty,state))
        }
        let goals = Dictionary(uniqueKeysWithValues:ends.enumerated().map { (index($0.element.outer),$0.offset) })
        var bestCost = CGFloat.infinity, finish: (Int,Int)?
        while let (cost,state) = queue.pop() {
            guard cost == distance[state] else { continue }
            if cost > bestCost { break }
            let node = state/3, axis = state%3
            if let port = goals[node] {
                let total = cost+(axis == ends[port].axis ? 0 : 20)+(port < 4 ? 0 : 12)
                if total < bestCost { bestCost = total; finish = (state,port) }
            }
            for (next,direction,length) in neighbors[node] {
                let nextState = next*3+direction, value = cost+length+(axis == direction ? 0 : 20)
                if value < distance[nextState] {
                    distance[nextState] = value; parent[nextState] = state; origin[nextState] = origin[state]
                    queue.push((value,nextState))
                }
            }
        }
        guard let (state,port) = finish else { return [] }
        var cursor = state, result = [ends[port].point]
        while cursor >= 0 { result.append(point(cursor/3)); cursor = parent[cursor] }
        result.append(starts[origin[state]].point); result.reverse()
        var simplified: [CGPoint] = []
        for p in result {
            if simplified.last == p { continue }
            if simplified.count >= 2 {
                let a = simplified[simplified.count-2], b = simplified.last!
                if (a.x == b.x && b.x == p.x) || (a.y == b.y && b.y == p.y) { simplified.removeLast() }
            }
            simplified.append(p)
        }
        return simplified
    }
    static func path(_ points: [CGPoint]) -> CGPath {
        let result = CGMutablePath()
        guard let first = points.first else { return result }
        result.move(to:first)
        for i in 1..<points.count {
            let p = points[i]
            guard i+1 < points.count else { result.addLine(to:p); break }
            let a = points[i-1], b = points[i+1]
            let before = hypot(p.x-a.x,p.y-a.y), after = hypot(b.x-p.x,b.y-p.y)
            let radius = min(20,before/2,after/2)
            let entry = CGPoint(x:p.x+(a.x-p.x)*radius/max(1,before),y:p.y+(a.y-p.y)*radius/max(1,before))
            let exit = CGPoint(x:p.x+(b.x-p.x)*radius/max(1,after),y:p.y+(b.y-p.y)*radius/max(1,after))
            result.addLine(to:entry); result.addQuadCurve(to:exit,control:p)
        }
        return result
    }
    private struct Queue {
        var items: [(CGFloat,Int)] = []
        mutating func push(_ item: (CGFloat,Int)) {
            items.append(item); var i = items.count-1
            while i > 0 {
                let parent = (i-1)/2
                if items[parent].0 <= items[i].0 { break }
                items.swapAt(parent,i); i = parent
            }
        }
        mutating func pop() -> (CGFloat,Int)? {
            guard !items.isEmpty else { return nil }
            let first = items[0], last = items.removeLast()
            guard !items.isEmpty else { return first }
            items[0] = last; var i = 0
            while i*2+1 < items.count {
                var child = i*2+1
                if child+1 < items.count && items[child+1].0 < items[child].0 { child += 1 }
                if items[i].0 <= items[child].0 { break }
                items.swapAt(i,child); i = child
            }
            return first
        }
    }
}

#if os(iOS)
final class BookGraphScrollView: UIScrollView {
    var layoutViewport: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); layoutViewport?() }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

struct BookGraphViewport<Content: View>: UIViewRepresentable {
    let content: Content
    let canvasSize: CGSize
    let scale: Double
    let focus: CGPoint
    let focusRequest: UUID
    func makeCoordinator() -> Coordinator { Coordinator(content:content) }
    func makeUIView(context: Context) -> BookGraphScrollView {
        let view = BookGraphScrollView()
        view.accessibilityIdentifier = "book-note-graph-viewport"
        view.backgroundColor = .clear
        view.isDirectionalLockEnabled = false
        view.alwaysBounceHorizontal = true; view.alwaysBounceVertical = true
        view.delaysContentTouches = true; view.canCancelContentTouches = true
        view.contentInsetAdjustmentBehavior = .never
        context.coordinator.host.view.backgroundColor = .clear
        view.addSubview(context.coordinator.host.view)
        view.layoutViewport = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }; coordinator?.layout(view)
        }
        return view
    }
    func updateUIView(_ view: BookGraphScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.host.rootView = content
        if let previous = coordinator.scale, previous != scale {
            let ratio = scale/previous
            view.contentOffset = CGPoint(x:(view.contentOffset.x+view.bounds.width/2)*ratio-view.bounds.width/2,
                                         y:(view.contentOffset.y+view.bounds.height/2)*ratio-view.bounds.height/2)
        }
        coordinator.scale = scale
        if coordinator.focusRequest != focusRequest { coordinator.pendingFocus = focus; coordinator.focusRequest = focusRequest }
        coordinator.host.view.frame = CGRect(origin:.zero,size:canvasSize)
        view.contentSize = canvasSize
        view.setNeedsLayout()
    }
    final class Coordinator {
        let host: UIHostingController<Content>
        var scale: Double?
        var focusRequest: UUID?
        var pendingFocus: CGPoint?
        init(content: Content) { host = UIHostingController(rootView:content) }
        func layout(_ view: UIScrollView) {
            guard view.bounds.width > 0, view.bounds.height > 0, !view.isTracking, !view.isDragging, !view.isDecelerating else { return }
            let target: CGPoint
            if let point = pendingFocus {
                target = BookGraphViewportPosition.centered(on:point,canvas:view.contentSize,viewport:view.bounds.size)
                pendingFocus = nil
            } else { target = BookGraphViewportPosition.clamp(view.contentOffset,canvas:view.contentSize,viewport:view.bounds.size) }
            if view.contentOffset != target { view.setContentOffset(target,animated:false) }
        }
    }
}
#else
final class BookGraphMacScrollView: NSScrollView {
    var layoutViewport: (() -> Void)?
    override func layout() { super.layout(); layoutViewport?() }
}
struct BookGraphViewport<Content: View>: NSViewRepresentable {
    let content: Content
    let canvasSize: CGSize
    let scale: Double
    let focus: CGPoint
    let focusRequest: UUID
    func makeCoordinator() -> Coordinator { Coordinator(content:content) }
    func makeNSView(context: Context) -> BookGraphMacScrollView {
        let view = BookGraphMacScrollView()
        view.identifier = .init("book-note-graph-viewport")
        view.drawsBackground = false; view.borderType = .noBorder
        view.hasHorizontalScroller = true; view.hasVerticalScroller = true; view.autohidesScrollers = true
        view.documentView = context.coordinator.host
        let pan = NSPanGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pan(_:)))
        pan.buttonMask = 1
        view.addGestureRecognizer(pan)
        context.coordinator.scrollView = view
        view.layoutViewport = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }; coordinator?.layout(view)
        }
        return view
    }
    func updateNSView(_ view: BookGraphMacScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.host.rootView = content
        var origin = view.contentView.bounds.origin
        if let previous = coordinator.scale, previous != scale {
            let ratio = scale/previous
            origin = CGPoint(x:(origin.x+view.contentSize.width/2)*ratio-view.contentSize.width/2,
                             y:(origin.y+view.contentSize.height/2)*ratio-view.contentSize.height/2)
        }
        coordinator.scale = scale
        coordinator.host.frame = CGRect(origin:.zero,size:canvasSize)
        if coordinator.focusRequest != focusRequest {
            coordinator.pendingFocus = focus
            coordinator.focusRequest = focusRequest
        }
        view.contentView.scroll(to:BookGraphViewportPosition.clamp(origin,canvas:canvasSize,viewport:view.contentSize))
        view.reflectScrolledClipView(view.contentView)
        view.needsLayout = true
    }
    final class Coordinator: NSObject {
        let host: NSHostingView<Content>
        weak var scrollView: NSScrollView?
        var scale: Double?
        var focusRequest: UUID?
        var pendingFocus: CGPoint?
        private var panOrigin = CGPoint.zero
        init(content: Content) { host = NSHostingView(rootView:content) }
        func layout(_ view: NSScrollView) {
            guard view.contentSize.width > 0, view.contentSize.height > 0 else { return }
            let origin: CGPoint
            if let point = pendingFocus {
                origin = BookGraphViewportPosition.centered(on:point,canvas:host.frame.size,viewport:view.contentSize)
                pendingFocus = nil
            } else { origin = BookGraphViewportPosition.clamp(view.contentView.bounds.origin,canvas:host.frame.size,viewport:view.contentSize) }
            if view.contentView.bounds.origin != origin {
                view.contentView.scroll(to:origin); view.reflectScrolledClipView(view.contentView)
            }
        }
        @objc func pan(_ gesture: NSPanGestureRecognizer) {
            guard let view = scrollView else { return }
            if gesture.state == .began { panOrigin = view.contentView.bounds.origin }
            let delta = gesture.translation(in:view)
            let origin = CGPoint(x:panOrigin.x-delta.x,y:panOrigin.y+delta.y)
            view.contentView.scroll(to:BookGraphViewportPosition.clamp(origin,canvas:host.frame.size,viewport:view.contentSize))
            view.reflectScrolledClipView(view.contentView)
        }
    }
}
#endif
