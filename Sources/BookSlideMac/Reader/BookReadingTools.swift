import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// A source-backed node entry point into the shared graph.
struct ReadingEntityFromSelection: View {
    @ObservedObject var reader: ReaderModel
    let draft: ReaderAnnotationDraft
    var embedded = false
    var cancel: (() -> Void)?
    var recorded: ((UUID) -> Void)?
    @State private var name: String
    @State private var kind = BookEntityKind.other
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var palette: BookGraphPalette { .init(dark:colorScheme == .dark,readingTheme:embedded ? reader.appearance.theme : nil) }
    init(reader: ReaderModel,draft: ReaderAnnotationDraft,embedded: Bool = false,cancel: (() -> Void)? = nil,recorded: ((UUID) -> Void)? = nil) {
        self.reader = reader; self.draft = draft; self.embedded = embedded; self.cancel = cancel; self.recorded = recorded
        let quote = draft.annotation.quote.trimmingCharacters(in:.whitespacesAndNewlines)
        _name = State(initialValue:quote.count <= 80 ? quote : "")
    }
    private var nameIssue: String? {
        let value = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.isEmpty { return "请为这段原文填写节点名称。" }
        if value.count > 80 { return "节点名称最多 80 个字。" }
        return nil
    }
    private func cancelEditing() { if let cancel { cancel() } else { dismiss() } }
    var body: some View {
        VStack(spacing:0) {
            ReadingEditorHeader(title:"新节点",symbol:"plus.circle",back:embedded ? cancelEditing : nil,backLabel:"取消添加节点") {
                if !embedded { ReadingToolButton(symbol:"xmark",label:"取消添加节点",action:cancelEditing) }
            }.padding(.horizontal,ReadingInterface.inset).padding(.vertical,8)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ReadingSourceCard(chapter:draft.annotation.chapter,text:draft.annotation.quote,lineLimit:4)
                    ReadingNodeComposer(name:$name,kind:$kind,placeholder:"为这段原文命名") {
                        Button("添加") {
                            guard let id = reader.recordSelectedEntity(name:name,kind:kind,source:draft.annotation,bookID:draft.bookID) else { failure = reader.error ?? "未能添加节点，请重试。"; return }
                            if let recorded { recorded(id) }
                            else {
                                dismiss(); reader.selectionEntity = nil; reader.openNoteGraph()
                                reader.selectReadingItem(.node(.init(.entity,id.uuidString)))
                            }
                        }.disabled(nameIssue != nil || reader.currentID != draft.bookID).accessibilityLabel("添加节点").accessibilityIdentifier("record-selection-node")
                    }
                    if let nameIssue { Text(nameIssue).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("selection-node-name-issue") }
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }.padding(.horizontal,ReadingInterface.inset).padding(.top,4).padding(.bottom,16)
                    .background(GeometryReader { proxy in Color.clear.preference(key:ReadingNodeComposerHeight.self,value:proxy.size.height+60) })
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).foregroundStyle(palette.ink).tint(palette.accent)
            .modifier(ReadingCreationSurface(floating:!embedded,palette:palette))
        #if os(iOS)
        .presentationDetents([.height(350),.large]).presentationDragIndicator(.visible)
        #else
        .frame(width:420,height:350)
        #endif
    }
}

/// These editors live in the graph inspector; creating a relationship does not
/// require inventing a note or source excerpt first.
struct BookGraphNewEntity: View {
    @ObservedObject var reader: ReaderModel
    @State private var kind: BookEntityKind
    let palette: BookGraphPalette
    let select: (BookGraphSelection) -> Void
    var floating = false
    private let bookID: UUID?
    @State private var name = ""
    @State private var aliases = ""
    @State private var failure: String?
    init(reader: ReaderModel, kind: BookEntityKind, palette: BookGraphPalette,floating: Bool = false, select: @escaping (BookGraphSelection) -> Void) {
        self.reader = reader; self.palette = palette; self.select = select
        self.floating = floating; bookID = reader.currentID
        _kind = State(initialValue:kind)
    }
    var body: some View {
        VStack(spacing:0) {
            ReadingEditorHeader(title:"新节点",symbol:"plus.circle",back:floating ? nil : { select(.entities) },backLabel:"取消添加节点") {
                if floating { ReadingToolButton(symbol:"xmark",label:"取消添加节点") { select(.entities) } }
            }.padding(.horizontal,ReadingInterface.inset).padding(.vertical,8)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ReadingNodeComposer(name:$name,kind:$kind,accessibilityName:"新节点名称") {
                        Button("添加") {
                            let names = aliases.components(separatedBy:CharacterSet(charactersIn:"、,，;；\n"))
                            if let id = reader.saveKnowledgeEntity(BookEntity(name:name,kind:kind,aliases:names),bookID:bookID) { select(.entity(id)) }
                            else { failure = reader.error }
                        }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || reader.currentID != bookID).accessibilityLabel("添加节点")
                    }
                    TextField("别名，用顿号分隔（可选）",text:$aliases).modifier(ReadingFieldSurface())
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }.padding(.horizontal,ReadingInterface.inset).padding(.top,4).padding(.bottom,16)
                    .background(GeometryReader { proxy in Color.clear.preference(key:ReadingNodeComposerHeight.self,value:proxy.size.height+60) })
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).modifier(ReadingCreationSurface(floating:floating,palette:palette)).tint(palette.accent)
        #if os(iOS)
        .presentationDetents([.height(330),.large]).presentationDragIndicator(.visible)
        #else
        .frame(width:floating ? 420 : nil,height:floating ? 330 : nil)
        #endif
    }

}

struct BookGraphRelationEditor: View {
    @ObservedObject var reader: ReaderModel
    let original: BookRelation?
    let palette: BookGraphPalette
    let includeFuture: Bool
    let select: (BookGraphSelection) -> Void
    private let bookID: UUID?
    @State private var source: UUID?
    @State private var target: UUID?
    @State private var label: String
    @State private var conjecture: Bool
    @State private var status: String?
    @State private var failure: String?
    @State private var addingEvidence = false
    @State private var evidenceIDs: [String]
    @State private var deleted = false
    @State private var draftID: UUID
    @State private var baseline: BookRelationDraft
    @State private var finished = false
    @Environment(\.scenePhase) private var scenePhase
    init(reader: ReaderModel,original: BookRelation?,sourceID: UUID? = nil,palette: BookGraphPalette,includeFuture: Bool,select: @escaping (BookGraphSelection) -> Void) {
        self.reader = reader; self.original = original; self.palette = palette; self.includeFuture = includeFuture; self.select = select
        bookID = reader.currentID
        let initial = BookRelationDraft(originalID:original?.id,sourceID:original?.sourceID ?? sourceID,targetID:original?.targetID,label:original?.label ?? "",conjecture:original?.conjecture ?? false,evidenceIDs:original?.evidenceIDs ?? [])
        let saved = reader.currentBook?.relationDrafts?.last { $0.originalID == original?.id && (original != nil || sourceID == nil || $0.sourceID == sourceID) }
        let value = saved ?? initial
        _source = State(initialValue:value.sourceID); _target = State(initialValue:value.targetID)
        _label = State(initialValue:value.label); _conjecture = State(initialValue:value.conjecture)
        _evidenceIDs = State(initialValue:value.evidenceIDs); _draftID = State(initialValue:value.id)
        _baseline = State(initialValue:BookRelationDraft(id:value.id,originalID:initial.originalID,sourceID:initial.sourceID,targetID:initial.targetID,label:initial.label,conjecture:initial.conjecture,evidenceIDs:initial.evidenceIDs))
        _status = State(initialValue:saved == nil ? nil : "已恢复关系草稿")
    }
    private var visibleNotes: [BookGraphNote] {
        let saved = Set(reader.currentAnnotations.map(\.id) + reader.currentPageNotes.map { $0.id.uuidString })
        return reader.bookNotesIndex.visibleNotes(through:reader.noteVisibilityProgress,includeFuture:includeFuture).filter { saved.contains($0.id) }
    }
    private var entities: [BookEntity] { reader.bookNotesIndex.entities }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Button { select(.entities) } label: { Label("返回图中",systemImage:"chevron.left") }.buttonStyle(.plain)
                Label(original == nil ? "添加关系" : "关系与依据",systemImage:"point.3.connected.trianglepath.dotted").font(.headline)
                if deleted {
                    Text("关系已移除").font(.title2)
                    Button("撤销移除") {
                        if let id = original?.id, reader.setRelationDeleted(id,deleted:false) { deleted = false; status = "已恢复" }
                        else { failure = reader.error }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Text("选择或新建两个事物，写下它们的关系。无需先写笔记。").font(.callout).foregroundStyle(.secondary)
                    BookRelationEndpoint(reader:reader,title:"起点",selected:$source,excluding:target,palette:palette,includeFuture:includeFuture)
                    HStack {
                        Image(systemName:"arrow.down").foregroundStyle(palette.accent)
                        TextField("关系，例如：加入、位于、导致",text:$label).textFieldStyle(.roundedBorder).accessibilityLabel("关系名称")
                        Button { let previous = source; source = target; target = previous } label: { Image(systemName:"arrow.up.arrow.down").frame(width:44,height:44).contentShape(Rectangle()) }
                            .buttonStyle(.borderless).accessibilityLabel("交换关系起点和终点")
                    }
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack {
                            ForEach(suggestedLabels,id:\.self) { suggestion in
                                Button(suggestion) { label = suggestion }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }.accessibilityLabel("常用关系，亦可自行填写")
                    BookRelationEndpoint(reader:reader,title:"终点",selected:$target,excluding:source,palette:palette,includeFuture:includeFuture)
                    if let a = entities.first(where:{$0.id == source}), let b = entities.first(where:{$0.id == target}), !label.isEmpty {
                        Text("\(a.name) — \(label) → \(b.name)").font(.system(size:21,design:.serif)).foregroundStyle(palette.accent)
                    }
                    Toggle("这是我的推测",isOn:$conjecture).font(.callout)
                    Divider()
                    HStack { Text("相关原文与记录").font(.headline); Spacer(); Button { addingEvidence.toggle() } label: { Image(systemName:"plus").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("添加关系依据") }
                    if evidenceIDs.isEmpty { Text("可以只记关系。原文和想法随时再补。").font(.callout).foregroundStyle(.secondary) }
                    ForEach(visibleNotes.filter { evidenceIDs.contains($0.id) }) { note in
                        HStack(alignment:.top) {
                            Button { select(.note(note.id)) } label: { BookReadingNoteRow(note:note) }.buttonStyle(.plain)
                            Button { evidenceIDs.removeAll { $0 == note.id } } label: { Image(systemName:"minus.circle").frame(width:44,height:44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("解除依据：\(note.title)")
                        }
                    }
                    if addingEvidence {
                        if !reader.textNoteDrafts.isEmpty { Text("新笔记需先保存，才能作为关系依据。").font(.caption).foregroundStyle(.secondary) }
                        if visibleNotes.filter({ !evidenceIDs.contains($0.id) }).isEmpty { Text("暂无可添加的记录。可以先保存关系，之后再补依据。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(visibleNotes.filter { !evidenceIDs.contains($0.id) }) { note in
                            Button { evidenceIDs.append(note.id); addingEvidence = false } label: { BookReadingNoteRow(note:note) }.buttonStyle(.plain)
                        }
                    }
                    if !evidenceIDs.isEmpty || addingEvidence { Text("修改依据后，点保存关系。").font(.caption).foregroundStyle(.secondary) }
                    if original != nil {
                        Divider()
                        Button("移除关系",role:.destructive) {
                            if let id = original?.id, reader.setRelationDeleted(id,deleted:true) {
                                deleted = true; finished = true
                                _ = reader.keepRelationDraft(draftValue,discard:true)
                            }
                            else { failure = reader.error }
                        }.buttonStyle(.borderless)
                    }
                }
            }.padding(26).frame(maxWidth:.infinity,alignment:.leading)
        }.background(palette.paper)
        .safeAreaInset(edge:.bottom,spacing:0) {
            if !deleted || failure != nil {
                VStack(spacing:0) {
                    Divider()
                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.red)
                            .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,24).padding(.top,8)
                    }
                    if !deleted { HStack {
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength:0)
                        Button { save() } label: {
                            Text("保存关系").font(.subheadline.weight(.medium)).padding(.horizontal,20).frame(height:38)
                                .foregroundStyle(Color.white).background(palette.accent,in:Capsule())
                                .frame(minHeight:44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(source == nil || target == nil || source == target || label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }.padding(.horizontal,24).padding(.vertical,8) }
                }.background(palette.paper)
            }
        }
        .task(id:draftValue) {
            do { try await Task.sleep(for:.milliseconds(450)) } catch { return }
            if !Task.isCancelled { keepDraft() }
        }
        .onDisappear { keepDraft() }
        .onChange(of:scenePhase) { phase in if phase != .active { keepDraft() } }
        .onChange(of:draftValue) { _ in finished = false; status = nil }
    }
    private var suggestedLabels: [String] {
        let previous = reader.bookNotesIndex.visibleRelations(through:reader.noteVisibilityProgress,includeFuture:includeFuture).map(\.label)
        var seen = Set<String>()
        return Array((previous + ["属于","位于","加入","拥有","参与","导致","包含","是师父","支持","反驳"]).filter { seen.insert($0).inserted }.prefix(12))
    }
    private var draftValue: BookRelationDraft {
        BookRelationDraft(id:draftID,originalID:original?.id,sourceID:source,targetID:target,label:label,conjecture:conjecture,evidenceIDs:evidenceIDs)
    }
    private func keepDraft() {
        guard !finished, reader.currentID == bookID else { return }
        let value = draftValue
        if value == baseline {
            if reader.currentBook?.relationDrafts?.contains(where: { $0.id == draftID }) == true { _ = reader.keepRelationDraft(value,discard:true) }
            return
        }
        if reader.keepRelationDraft(value) { status = "草稿已保留"; failure = nil }
        else { failure = reader.error ?? "草稿未能保留，请先保存关系。" }
    }
    private func save() {
        guard reader.currentID == bookID, let source, let target else { return }
        var value = original ?? BookRelation(sourceID:source,targetID:target,label:label,evidenceIDs:[])
        value.sourceID = source; value.targetID = target; value.label = label; value.conjecture = conjecture; value.evidenceIDs = evidenceIDs
        if let id = reader.saveIndependentRelation(value,draftID:draftID) {
            finished = true; baseline = draftValue; failure = nil; status = "已保存"; select(.relation(id))
        }
        else { failure = reader.error }
    }
}

private struct BookRelationEndpoint: View {
    @ObservedObject var reader: ReaderModel
    let title: String
    @Binding var selected: UUID?
    let excluding: UUID?
    let palette: BookGraphPalette
    let includeFuture: Bool
    @State private var creating = false
    @State private var name = ""
    @State private var kind = BookEntityKind.other
    @State private var failure: String?
    private var entities: [BookEntity] {
        reader.bookNotesIndex.entities.filter { $0.id != excluding && (includeFuture || $0.id == selected || ($0.progress ?? 0) <= reader.noteVisibilityProgress + 0.0001) }
    }
    private var matches: [BookEntity] { entities.filter { name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || $0.matches(name.trimmingCharacters(in:.whitespacesAndNewlines)) } }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let entity = entities.first(where: { $0.id == selected }) {
                HStack {
                    Label(entity.name,systemImage:entity.kind.symbol).font(.callout.weight(.medium))
                    Text(entity.kind.title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength:0)
                    Button(creating ? "收起" : "更换") { creating.toggle(); name = "" }.buttonStyle(.borderless)
                }
            }
            if creating || !entities.contains(where: { $0.id == selected }) {
                TextField("搜索名称或别名，也可新建",text:$name).textFieldStyle(.roundedBorder).accessibilityLabel("\(title)事物名称或别名")
                ForEach(Array(matches.prefix(6))) { entity in
                    Button { selected = entity.id; creating = false; name = ""; failure = nil } label: {
                        HStack {
                            Label(entity.name,systemImage:entity.kind.symbol)
                            Spacer(minLength:0)
                            Text(entity.kind.title).font(.caption).foregroundStyle(.secondary)
                        }.font(.callout).padding(.vertical,5).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(title)选择\(entity.kind.title)：\(entity.name)")
                }
                if matches.count > 6 { Text("还有 \(matches.count - 6) 项，输入名称缩小范围。").font(.caption).foregroundStyle(.secondary) }
                if !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                HStack {
                    Picker("类型",selection:$kind) { ForEach(BookEntityKind.allCases,id:\.self) { Text($0.title).tag($0) } }.labelsHidden()
                    Button("新建并选择") {
                        if let id = reader.saveKnowledgeEntity(BookEntity(name:name,kind:kind)) {
                            if id == excluding { failure = "起点和终点需要选择不同的事物。" }
                            else { selected = id; creating = false; name = ""; failure = nil }
                        }
                        else { failure = reader.error }
                    }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                }
                if entities.isEmpty && name.isEmpty { Text("输入名称，即可在这里创建事物。").font(.caption).foregroundStyle(.secondary) }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(palette.background,in:RoundedRectangle(cornerRadius:10))
    }
}

/// A dedicated inventory of things and their relationships, independent of notes.
struct BookGraphThingsLibrary: View {
    @ObservedObject var reader: ReaderModel
    let palette: BookGraphPalette
    let includeFuture: Bool
    var focusesOnPeople = false
    let select: (BookGraphSelection) -> Void
    @State private var showRelations = true
    @State private var query = ""
    @State private var kind: BookEntityKind?
    private var index: BookNotesIndex { reader.bookNotesIndex }
    private var entities: [BookEntity] { index.matchingEntities(query,kind:kind,through:reader.noteVisibilityProgress,includeFuture:includeFuture) }
    private var relations: [BookRelation] { index.matchingRelations(query,kind:kind,through:reader.noteVisibilityProgress,includeFuture:includeFuture) }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Label(focusesOnPeople ? "人物关系" : "事物与关系",systemImage:"point.3.connected.trianglepath.dotted").font(.title2)
                Text(focusesOnPeople ? "整理书中的人物与关系，也可记录地点、组织等。" : "把书中的人物、组织、地点、物品、事件和概念连起来。关系可以独立记录，原文依据随时补充。").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button { select(.newEvent) } label: { Label("添加事件",systemImage:"arrow.triangle.branch") }.buttonStyle(.borderedProminent)
                    Button { select(.newEntity(.other)) } label: { Label("添加笔记",systemImage:"square.and.pencil") }.buttonStyle(.bordered)
                }
                Picker("查看",selection:$showRelations) {
                    Text("关系").tag(true)
                    Text("事物").tag(false)
                }.pickerStyle(.segmented)
                TextField("搜索事物、别名或关系",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索事物与关系")
                Picker("事物类型",selection:$kind) {
                    Text("全部类型").tag(nil as BookEntityKind?)
                    ForEach(BookEntityKind.allCases,id:\.self) { Text($0.title).tag(Optional($0)) }
                }
                Text(includeFuture ? "显示全部记录（含后文）" : "显示截至最远已读的记录").font(.caption).foregroundStyle(.secondary)
                if showRelations {
                    Text("\(relations.count) 条关系").font(.caption).foregroundStyle(.secondary)
                    if relations.isEmpty { emptyState }
                    ForEach(relations) { relation in
                        Button { select(.relation(relation.id)) } label: {
                            VStack(alignment:.leading,spacing:9) {
                                endpoint(relation.sourceID)
                                Label(relation.label,systemImage:"arrow.down").font(.callout.weight(.medium)).foregroundStyle(palette.accent).padding(.leading,5)
                                endpoint(relation.targetID)
                                HStack {
                                    if relation.conjecture { Label("我的推测",systemImage:"questionmark.circle") }
                                    let count = index.visibleNotes(through:reader.noteVisibilityProgress,includeFuture:includeFuture).filter { relation.evidenceIDs.contains($0.id) }.count
                                    Text(count == 0 ? "依据可后补" : "\(count) 条依据")
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(palette.background,in:RoundedRectangle(cornerRadius:10))
                    }
                } else {
                    Text("\(entities.count) 个事物").font(.caption).foregroundStyle(.secondary)
                    if entities.isEmpty { emptyState }
                    ForEach(entities) { entity in
                        Button { select(.entity(entity.id)) } label: {
                            VStack(alignment:.leading,spacing:6) {
                                HStack {
                                    Label(entity.name,systemImage:entity.kind.symbol).font(.callout.weight(.medium))
                                    Spacer(minLength:0)
                                    Text(entity.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                                if !entity.aliases.isEmpty { Text(entity.aliases.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(palette.background,in:RoundedRectangle(cornerRadius:10))
                    }
                }
                recovery
            }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
        }.background(palette.paper)
    }
    private var emptyState: some View {
        Text(query.isEmpty && kind == nil ? (showRelations ? "还没有关系。点「添加关系」，可以直接创建两端的事物。" : "还没有事物。可以先创建卡片，也可以在添加关系时创建。") : "没有匹配结果，试试其他关键词或类型。")
            .font(.callout).foregroundStyle(.secondary).padding(.vertical,12)
    }
    @ViewBuilder private func endpoint(_ id: UUID) -> some View {
        if let entity = index.entities.first(where: { $0.id == id }) {
            Label(entity.name,systemImage:entity.kind.symbol).font(.callout).fixedSize(horizontal:false,vertical:true)
        }
    }
    @ViewBuilder private var recovery: some View {
        let removedEntities = (reader.currentBook?.knowledgeEntities ?? []).filter { $0.deletedAt != nil }
        let removedRelations = (reader.currentBook?.knowledgeRelations ?? []).filter { $0.deletedAt != nil }
        if !removedEntities.isEmpty || !removedRelations.isEmpty {
            DisclosureGroup("已移除的事物与关系") {
                ForEach(removedEntities) { entity in
                    Button("恢复事物：\(entity.name)") { _ = reader.setKnowledgeEntityDeleted(entity.id,deleted:false) }.buttonStyle(.borderless).padding(.vertical,6)
                }
                ForEach(removedRelations) { relation in
                    Button("恢复关系：\(relation.label)") { _ = reader.setRelationDeleted(relation.id,deleted:false) }.buttonStyle(.borderless).padding(.vertical,6)
                }
            }
        }
    }
}

struct BookReadingNoteRow: View {
    let note: BookGraphNote
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Label(note.title,systemImage:note.ink ? "pencil.tip" : "text.quote").font(.callout.weight(.medium)).lineLimit(2)
            Text(note.chapter).font(.caption).foregroundStyle(.secondary)
            if !note.quote.isEmpty && note.quote != note.title { Text(note.quote).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Divider()
        }.padding(.vertical,7).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
    }
}

/// A plain subject–action–object form. New endpoints stay local until Save.
struct BookGraphEventComposer: View {
    @ObservedObject var reader: ReaderModel
    let palette: BookGraphPalette
    var close: (() -> Void)?
    let saved: (ReadingEdge.ID) -> Void
    private let bookID: UUID?
    @State private var source = BookEntity(name:"",kind:.person)
    @State private var target = BookEntity(name:"",kind:.person)
    @State private var sourceNode: ReadingNodeID?
    @State private var targetNode: ReadingNodeID?
    @State private var action = ""
    @State private var note = ""
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    init(reader: ReaderModel,palette: BookGraphPalette,close: (() -> Void)? = nil,saved: @escaping (ReadingEdge.ID) -> Void) {
        self.reader = reader; self.palette = palette; self.close = close; self.saved = saved; bookID = reader.currentID
        if case .node(let id) = reader.selectedReadingItem,
           [.entity,.note,.ink,.discussion].contains(id.kind), let node = reader.currentBook?.graph.node(id), node.deletedAt == nil {
            _sourceNode = State(initialValue:id)
            if case .entity(let entity) = node.content { _source = State(initialValue:entity) }
            else { _source = State(initialValue:BookEntity(name:reader.currentBook?.graph.title(for:id) ?? node.title,kind:.other)) }
        }
    }
    private var valid: Bool {
        let a = source.name.trimmingCharacters(in:.whitespacesAndNewlines)
        let b = target.name.trimmingCharacters(in:.whitespacesAndNewlines)
        let label = action.trimmingCharacters(in:.whitespacesAndNewlines)
        return (sourceNode != nil || (!a.isEmpty && a.count <= 80)) && (targetNode != nil || (!b.isEmpty && b.count <= 80)) && (sourceNode == nil || sourceNode != targetNode)
            && !label.isEmpty && label.count <= 60 && note.count <= 100_000 && bookID == reader.currentID
    }
    private func cancel() { if let close { close() } else { dismiss() } }
    var body: some View {
        VStack(spacing:0) {
            ReadingEditorHeader(title:"添加事件",symbol:"arrow.triangle.branch",back:close == nil ? nil : cancel,backLabel:"取消添加事件") {
                if close == nil { ReadingToolButton(symbol:"xmark",label:"取消添加事件",action:cancel) }
            }.padding(.horizontal,20).padding(.vertical,8)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text("谁 → 做了什么 → 谁或什么").font(.headline)
                    Text("填写名称即可新建节点，也可选择已有节点。保存时一起添加节点和连线。").font(.callout).foregroundStyle(.secondary)
                    endpoint("谁（起点）",value:$source,selected:$sourceNode)
                    VStack(alignment:.leading,spacing:6) {
                        Label("做了什么（连线）",systemImage:"arrow.down").font(.subheadline)
                        TextField("例如：帮助、加入、发现",text:$action).modifier(ReadingFieldSurface()).accessibilityLabel("事件动作")
                    }
                    endpoint("谁或什么（终点）",value:$target,selected:$targetNode)
                    VStack(alignment:.leading,spacing:6) {
                        Text("补充笔记（可选）").font(.subheadline)
                        TextEditor(text:$note).font(.body).frame(minHeight:80).accessibilityLabel("事件补充笔记")
                            .overlay(RoundedRectangle(cornerRadius:8).stroke(palette.line).allowsHitTesting(false))
                    }
                    if valid {
                        Text("\(source.name) — \(action) → \(target.name)").font(.callout.weight(.medium)).foregroundStyle(palette.accent)
                            .accessibilityIdentifier("event-preview")
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }.padding(20)
            }
            ReadingCreationFooter(hint:"保存后在图中查看节点与连线。") {
                Button("保存事件") {
                    guard let bookID else { return }
                    if let edge = reader.saveReadingEvent(source:source,target:target,action:action,note:note,sourceNode:sourceNode,targetNode:targetNode,bookID:bookID) {
                        saved(edge)
                        if close == nil { dismiss() }
                    } else { failure = reader.error ?? "事件未能保存，请重试。" }
                }.disabled(!valid).accessibilityIdentifier("save-reading-event")
            }.padding(.horizontal,20).padding(.bottom,12)
        }.foregroundStyle(palette.ink).tint(palette.accent)
            .modifier(ReadingCreationSurface(floating:close == nil,palette:palette))
        #if os(iOS)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        #else
        .frame(width:close == nil ? 460 : nil,height:close == nil ? 680 : nil)
        #endif
    }
    private var existingNodes: [ReadingNode] {
        guard let graph = reader.currentBook?.graph else { return [] }
        return reader.bookNotesIndex.searchNodes("",through:reader.noteVisibilityProgress).filter {
            [.entity,.note,.ink,.discussion].contains($0.id.kind) && graph.node($0.id).map { $0.deletedAt == nil } == true
        }
    }
    private func endpoint(_ title: String,value: Binding<BookEntity>,selected: Binding<ReadingNodeID?>) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.subheadline)
            TextField("输入名称，或选择已有节点",text:Binding(get:{ value.wrappedValue.name },set:{ name in
                selected.wrappedValue = nil
                value.wrappedValue = BookEntity(name:name,kind:value.wrappedValue.kind)
            })).modifier(ReadingFieldSurface()).accessibilityLabel(title)
            HStack {
                if let id = selected.wrappedValue, id.kind != .entity {
                    Label("已选节点",systemImage:"note.text").foregroundStyle(.secondary)
                } else {
                Picker("节点类型",selection:Binding(get:{ value.wrappedValue.kind },set:{ kind in
                    selected.wrappedValue = nil
                    value.wrappedValue = BookEntity(name:value.wrappedValue.name,kind:kind)
                })) { ForEach(BookEntityKind.allCases,id:\.self) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                }
                Spacer(minLength:4)
                Menu("选择已有节点") {
                    ForEach(existingNodes) { node in
                        Button(reader.bookNotesIndex.graph.title(for:node.id) ?? node.title) {
                            selected.wrappedValue = node.id
                            if case .entity(let entity) = node.content { value.wrappedValue = entity }
                            else { value.wrappedValue = BookEntity(name:reader.bookNotesIndex.graph.title(for:node.id) ?? node.title,kind:.other) }
                        }
                    }
                }.disabled(existingNodes.isEmpty)
            }.font(.callout)
        }.padding(12).background(palette.background,in:RoundedRectangle(cornerRadius:10))
    }
}
