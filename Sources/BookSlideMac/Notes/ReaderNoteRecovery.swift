import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

extension ReaderModel {
    func isNoteRemoved(_ id: String,bookID: UUID) -> Bool {
        (books.first(where:{ $0.id == bookID })?.removedNotes ?? []).contains { !$0.noteOnly && $0.annotation?.id == id }
    }
    var noteDraftStore: ReaderNoteDraftStore { ReaderNoteDraftStore(libraryDirectory:directory) }
    var readingNodeDraftStore: ReadingNodeDraftStore { .init(libraryDirectory:directory) }
    func keepReadingNodeDraft(_ node: ReadingNode,bookID: UUID) throws {
        if currentID == bookID && readingNodeDrafts.contains(where:{ $0.id == node.id && $0.node == node }) { return }
        let draft = ReadingNodeDraft(bookID:bookID,node:node)
        try readingNodeDraftStore.save(draft)
        if currentID == bookID { readingNodeDrafts.removeAll { $0.id == node.id }; readingNodeDrafts.insert(draft,at:0) }
    }
    func discardReadingNodeDraft(_ id: ReadingNodeID,bookID: UUID) throws {
        try readingNodeDraftStore.remove(bookID:bookID,id:id)
        if currentID == bookID { readingNodeDrafts.removeAll { $0.id == id } }
    }
    var removedNotes: [ReaderRemovedNote] { (currentBook?.removedNotes ?? []).sorted { $0.removedAt > $1.removedAt } }
    var noteDraftCount: Int { textNoteDrafts.count + inkNoteDrafts.count + readingNodeDrafts.count }
    var recoverableNoteDraftCount: Int {
        #if os(iOS)
        return textNoteDrafts.count + inkNoteDrafts.filter { $0.id != inlineInk?.draft?.id }.count + readingNodeDrafts.count
        #else
        return noteDraftCount
        #endif
    }

    func loadNoteDrafts(bookID: UUID) {
        textNoteDrafts = []; inkNoteDrafts = []; readingNodeDrafts = []
        do {
            let book = books.first { $0.id == bookID }
            textNoteDrafts = try noteDraftStore.textDrafts(bookID:bookID).filter { draft in
                !(book?.annotations ?? []).contains { $0.id == draft.id && $0.updatedAt >= draft.updatedAt }
            }
            inkNoteDrafts = try noteDraftStore.inkDrafts(bookID:bookID).filter { draft in
                !(book?.pageNotes ?? []).contains { ($0.id == draft.id || $0.inkParts.contains(where:{ $0.canvasID==draft.id })) && $0.updatedAt >= draft.updatedAt }
            }
            readingNodeDrafts = try readingNodeDraftStore.drafts(bookID:bookID).filter { draft in
                book?.graph.node(draft.id)?.deletedAt == nil && book?.graph.node(draft.id) != nil
            }
        } catch { self.error = "草稿暂时无法读取，原文件已保留：\(error.localizedDescription)" }
    }
    func keepTextDraft(_ annotation: ReaderAnnotation, bookID: UUID) throws {
        if currentID == bookID, textNoteDrafts.contains(where:{ $0.bookID == bookID && $0.id == annotation.id && $0.annotation == annotation }) { return }
        let draft = ReaderTextNoteDraft(bookID:bookID,annotation:annotation)
        try noteDraftStore.save(draft)
        if currentID == bookID {
            var updated = textNoteDrafts.filter { $0.id != draft.id }
            updated.insert(draft,at:0)
            textNoteDrafts = updated
        }
    }
    func keepInkDraft(_ draft: ReaderInkNoteDraft) throws {
        try noteDraftStore.save(draft)
        if currentID == draft.bookID { inkNoteDrafts.removeAll { $0.id == draft.id }; inkNoteDrafts.insert(draft,at:0) }
    }
    func discardNoteDraft(bookID: UUID, id: UUID, ink: Bool) throws {
        try noteDraftStore.remove(bookID:bookID,id:id,ink:ink)
        if currentID == bookID {
            if ink, inkNoteDrafts.contains(where:{ $0.id == id }) { inkNoteDrafts.removeAll { $0.id == id } }
            else if !ink, textNoteDrafts.contains(where:{ UUID(uuidString:$0.id) == id }) { textNoteDrafts.removeAll { UUID(uuidString:$0.id) == id } }
        }
    }
    @discardableResult func restoreRemovedNote(_ id: UUID) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == currentID }),
              let removed = books[index].removedNotes?.first(where: { $0.id == id }) else { return false }
        var updated = books
        if var annotation = removed.annotation {
            var items = updated[index].annotations ?? []
            if let existing = items.firstIndex(where: { $0.id == annotation.id }) {
                guard items[existing].note.isEmpty || items[existing].note == annotation.note else {
                    error = "这处已有新的笔记。原笔记仍在最近删除中，请先保留新内容后再恢复。"; return false
                }
                if removed.noteOnly { items[existing].note = annotation.note; items[existing].updatedAt = Date() }
                else { annotation.updatedAt = Date(); items[existing] = annotation }
            } else { annotation.updatedAt = Date(); items.append(annotation) }
            updated[index].annotations = items
        }
        if var note = removed.pageNote {
            var notes = updated[index].pageNotes ?? []
            guard !notes.contains(where: { $0.id == note.id }) else { return false }
            let liveParts=Set(notes.flatMap(\.inkParts).map(\.id))
            guard note.inkParts.allSatisfy({ !liveParts.contains($0.id) }) else { error="这些标记已经在其他节点中，请先拆分已有节点。";return false }
            note.updatedAt = Date(); notes.append(note); updated[index].pageNotes = notes
        }
        updated[index].removedNotes?.removeAll { $0.id == id }
        guard commitReadingGraph(bookID:books[index].id,{ $0 = updated[index].graph }) else { return false }
        if noteUndoID == id { noteUndoID = nil }
        return true
    }
}

struct ReaderNoteRecoveryView: View {
    @ObservedObject var reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingGraphID: String?
    @State private var pendingNodeDraft: ReadingNodeDraft?
    @State private var recoveryError: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("草稿与最近删除").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    Text("草稿").font(.headline)
                    if reader.noteDraftCount == 0 { Text("没有未完成的笔记").foregroundStyle(.secondary) }
                    ForEach(reader.textNoteDrafts) { draft in
                        VStack(alignment:.leading,spacing:8) {
                            Text(draft.annotation.chapter).font(.caption).foregroundStyle(.secondary)
                            Text(draft.annotation.note.isEmpty ? draft.annotation.quote : draft.annotation.note).lineLimit(4)
                            Button("继续编辑") { pendingGraphID = draft.id; dismiss() }
                            Divider()
                        }
                    }
                    ForEach(reader.inkNoteDrafts) { draft in
                        VStack(alignment:.leading,spacing:8) {
                            Label(draft.note.anchor.chapter,systemImage:"pencil.tip")
                            #if os(iOS)
                            Button("回原文书写") { reader.resumePageHandwriting(draft.note); dismiss() }
                            #endif
                            Divider()
                        }
                    }
                    ForEach(reader.readingNodeDrafts) { draft in
                        VStack(alignment:.leading,spacing:8) {
                            Text(draft.node.title.isEmpty ? "未完成的卡片" : draft.node.title).font(.callout.weight(.medium))
                            Text(draft.node.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Button("继续编辑") { pendingNodeDraft = draft; dismiss() }
                            Divider()
                        }
                    }
                    Text("最近删除").font(.headline)
                    Text("删除的笔记保留在本机，可随时恢复。").font(.caption).foregroundStyle(.secondary)
                    if reader.removedNotes.isEmpty { Text("没有已删除的笔记").foregroundStyle(.secondary) }
                    ForEach(reader.removedNotes) { removed in
                        VStack(alignment:.leading,spacing:8) {
                            if let item = removed.annotation {
                                Text(item.chapter).font(.caption).foregroundStyle(.secondary)
                                Text(item.quote).lineLimit(3)
                                if !item.note.isEmpty { Text(item.note).lineLimit(4).foregroundStyle(.secondary) }
                            }
                            if let item = removed.pageNote { Label(item.anchor.chapter,systemImage:"pencil.tip") }
                            Button("恢复") {
                                if !reader.restoreRemovedNote(removed.id) { recoveryError = reader.error ?? "暂时无法恢复，请重试。" }
                            }.accessibilityLabel("恢复\(removed.annotation?.chapter ?? removed.pageNote?.anchor.chapter ?? "笔记")")
                            Divider()
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if let recoveryError { Text(recoveryError).font(.caption).foregroundStyle(.red) }
        }.padding(24)
        #if os(macOS)
        .frame(width:480,height:560)
        #else
        .presentationDetents([.large])
        #endif
        .onDisappear {
            if let draft = pendingNodeDraft {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.35) {
                    reader.openKnowledgeWorkspace(bookID:draft.bookID)
                    if reader.currentID == draft.bookID { reader.selectReadingItem(.node(draft.id)) }
                }
            }
            if let id = pendingGraphID {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.35) { reader.openNoteGraph(noteID:id) }
            }
        }
    }
}

struct ReaderNoteNotices: View {
    @ObservedObject var reader: ReaderModel
    @State private var recovery = false
    @State private var dismissedDraftBookID: UUID?
    private var actionSize: CGFloat {
        #if os(iOS)
        44
        #else
        22
        #endif
    }
    var body: some View {
        VStack(spacing:8) {
            if let id = reader.noteUndoID, reader.removedNotes.contains(where: { $0.id == id }) {
                HStack(spacing:12) {
                    Text("已移到最近删除")
                    Spacer(minLength:0)
                    Button("撤销") { reader.restoreRemovedNote(id) }.frame(minHeight:actionSize)
                    Button { reader.noteUndoID = nil } label: { Image(systemName:"xmark").frame(width:actionSize,height:actionSize) }.accessibilityLabel("收起删除提示")
                }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
            }
            if reader.recoverableNoteDraftCount > 0 && dismissedDraftBookID != reader.currentID {
                HStack(spacing:12) {
                    Text("有 \(reader.recoverableNoteDraftCount) 份未完成的笔记")
                    Spacer(minLength:0)
                    Button("继续编辑") { recovery = true }.frame(minHeight:actionSize)
                    Button { dismissedDraftBookID = reader.currentID } label: { Image(systemName:"xmark").frame(width:actionSize,height:actionSize) }.accessibilityLabel("收起草稿提示")
                }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
            }
            if let id = reader.hiddenPageNoteIDs.first, let note = reader.currentPageNotes.first(where: { $0.id == id }), !reader.handwritingActive {
                HStack {
                    Label("此处有手写批注",systemImage:"pencil.tip")
                    Spacer(minLength:0)
                    Button("查看原页") { reader.pageNoteToView = note }.frame(minHeight:actionSize)
                }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
            }
        }.font(.callout).frame(maxWidth:460).padding(12)
        .sheet(isPresented:$recovery) { ReaderNoteRecoveryView(reader:reader) }
        #if os(iOS)
        .onChange(of:recovery) { _,shown in
            reader.inlineInkObscured = shown
            if shown { _ = reader.inlineInk?.suspend() }
        }
        #endif
    }
}
