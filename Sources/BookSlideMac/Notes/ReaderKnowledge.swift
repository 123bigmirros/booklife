import Foundation
import WebKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

extension ChapterItem {
    var discussionScope: String { "chapter:\(id):\(href)" }
}

struct ReadingGraphSearchHit: Identifiable {
    struct ID: Hashable { var book: UUID; var item: ReadingGraphSelection }
    var bookID: UUID
    var bookTitle: String
    var item: ReadingGraphSelection
    var title: String
    var text: String
    var kind: ReadingNodeID.Kind?
    var id: ID { .init(book:bookID,item:item) }
}

extension ReaderModel {
    func searchReadingGraph(_ query: String, allBooks: Bool = true, includeFuture: Bool = false) -> [ReadingGraphSearchHit] {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        var results: [ReadingGraphSearchHit] = []
        for book in books where book.hidden != true && (allBooks || book.id == currentID) {
            let index = book.id == currentID ? bookNotesIndex : BookNotesIndex(entries:[],graph:book.graph)
            let progress = book.id == currentID ? noteVisibilityProgress : max(book.progress,book.furthestReadProgress ?? 0,(book.annotations ?? []).map(\.progress).max() ?? 0,(book.pageNotes ?? []).map { $0.anchor.progress }.max() ?? 0,book.graph.entities.compactMap(\.progress).max() ?? 0,book.graph.relations.compactMap(\.progress).max() ?? 0)
            for node in index.searchNodes(query,through:progress,includeFuture:includeFuture) {
                results.append(.init(bookID:book.id,bookTitle:book.title,item:.node(node.id),title:index.graph.title(for:node.id) ?? node.title,text:node.text,kind:node.id.kind))
                if results.count >= 200 { return results }
            }
            let visibleNodes = Set(index.searchNodes("",through:progress,includeFuture:includeFuture).map(\.id))
            for edge in index.graph.searchEdges(query) where visibleNodes.contains(edge.id.source) && visibleNodes.contains(edge.id.target) {
                let source = index.graph.title(for:edge.id.source) ?? "", target = index.graph.title(for:edge.id.target) ?? ""
                results.append(.init(bookID:book.id,bookTitle:book.title,item:.edge(edge.id),title:"\(source) → \(edge.label) → \(target)",text:"关系",kind:nil))
                if results.count >= 200 { return results }
            }
        }
        return results
    }
    @MainActor func openReadingSearchHit(_ hit: ReadingGraphSearchHit) {
        readingSelectionTask?.cancel(); readingSelectionTask = nil
        guard openKnowledgeWorkspace(bookID:hit.bookID) else { return }
        let selectionSession: UUID? = knowledgeOpenTask == nil ? sessionID : nil
        readingSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<150 {
                guard !Task.isCancelled else { return }
                if let selectionSession, sessionID != selectionSession { return }
                if currentID == hit.bookID && !loading && knowledgeOpenTask == nil { selectReadingItem(hit.item); return }
                if !loading && knowledgeOpenTask == nil && currentID != hit.bookID { return }
                try? await Task.sleep(for:.milliseconds(100))
            }
        }
    }
    /// Shared selection and transaction boundary for every node type.
    func selectReadingItem(_ item: ReadingGraphSelection) {
        readingSelectionTask?.cancel(); readingSelectionTask = nil
        switch item {
        case .node(let id):
            guard let node = bookNotesIndex.graph.node(id), node.deletedAt == nil else { return }
            let discussionSource = id.kind == .source && id.local != "excerpt"
            discussionFocusMessage = id.kind == .message ? id.local.flatMap(UUID.init(uuidString:)) : discussionSource ? id.local?.split(separator:"/").first.flatMap { UUID(uuidString:String($0)) } : nil
            discussionNoteID = [.discussion,.message].contains(id.kind) || discussionSource ? id.owner : nil
        case .edge(let id):
            guard bookNotesIndex.graph.edges.contains(where:{ $0.id == id && $0.deletedAt == nil }) else { return }
            discussionFocusMessage = nil; discussionNoteID = nil
        }
        selectedReadingItem = item
    }
    @discardableResult func commitReadingGraph(bookID: UUID, refresh: Bool = true, _ change: (inout ReadingGraph) throws -> Void) -> Bool {
        guard allowsLibraryWrites else { error = "书库尚未载入，请先恢复书库后再编辑。"; return false }
        guard let i = books.firstIndex(where:{ $0.id == bookID }) else { error = "原图书已移除，修改仍保留在编辑器中。"; return false }
        var updated = books
        do {
            try change(&updated[i].graph)
            let annotationsChanged = updated[i].graph.annotations != books[i].graph.annotations
            let inkChanged = updated[i].graph.pageNotes != books[i].graph.pageNotes
            try LibraryIndexStore(directory:directory).save(updated)
            books = updated
            if currentID == bookID, let selectedReadingItem {
                let graph = updated[i].graph
                let active: Bool
                switch selectedReadingItem {
                case .node(let id): active = graph.node(id).map { $0.deletedAt == nil } ?? false
                case .edge(let id): active = graph.edges.contains { $0.id == id && $0.deletedAt == nil && graph.node(id.source).map { $0.deletedAt == nil } == true && graph.node(id.target).map { $0.deletedAt == nil } == true }
                }
                if !active { self.selectedReadingItem = nil; discussionNoteID = nil; discussionFocusMessage = nil }
            }
            if refresh && currentID == bookID {
                if annotationsChanged { refreshAnnotations() }
                if inkChanged { refreshPageNotes() }
            }
            return true
        } catch { self.error = "修改未能保存：\(error.localizedDescription)"; return false }
    }
    @discardableResult func performReadingMutation(_ mutation: ReadingGraphMutation, bookID: UUID? = nil) -> Bool {
        guard let id = bookID ?? currentID else { return false }
        return commitReadingGraph(bookID:id) { try $0.apply(mutation) }
    }
    /// One manual connection API for people, notes, discussions and handwriting.
    /// The editor calls this only after the reader confirms both endpoints.
    func connectReadingNodes(from source: ReadingNodeID,to target: ReadingNodeID,label: String,bookID: UUID) -> ReadingEdge.ID? {
        let name = label.trimmingCharacters(in:.whitespacesAndNewlines)
        guard source != target, !name.isEmpty, name.count <= 160,
              let book = books.first(where:{ $0.id == bookID }) else { error = ReadingGraphError.invalidConnection.localizedDescription; return nil }
        guard let a = book.graph.node(source), a.deletedAt == nil, let b = book.graph.node(target), b.deletedAt == nil else {
            error = ReadingGraphError.missingEndpoint.localizedDescription; return nil
        }
        if let existing = book.graph.searchEdges("").first(where:{ $0.id.source == source && $0.id.target == target && $0.label == name }) { return existing.id }
        let edge = ReadingEdge(kind:.association,source:source,target:target,label:name,record:UUID())
        return performReadingMutation(.connect(edge),bookID:bookID) ? edge.id : nil
    }
    func revealReadingConnection(_ id: ReadingEdge.ID,bookID: UUID) {
        guard currentID == bookID, currentBook?.graph.searchEdges("").contains(where:{ $0.id == id }) == true else { return }
        showNoteGraph = true
        selectReadingItem(.edge(id))
        selectionDiscussion = nil
    }
    /// Returning to an earlier chapter must not hide the reader's own later notes.
    var noteVisibilityProgress: Double {
        guard let book = currentBook else { return 0 }
        let recorded: Double
        if let cachedNoteRecordProgress { recorded = cachedNoteRecordProgress }
        else {
            recorded = ((book.annotations ?? []).map(\.progress) + (book.pageNotes ?? []).map { $0.anchor.progress }
                + (book.knowledgeEntities ?? []).compactMap(\.progress) + (book.knowledgeRelations ?? []).compactMap(\.progress)).max() ?? 0
            cachedNoteRecordProgress = recorded
        }
        return max(position?.progress ?? book.progress, book.furthestReadProgress ?? book.progress, recorded)
    }
    var graphAnnotations: [ReaderAnnotation] {
        var values = currentAnnotations
        for draft in textNoteDrafts where draft.bookID == currentID {
            if let index = values.firstIndex(where: { $0.id == draft.id }) { values[index] = draft.annotation }
            else { values.append(draft.annotation) }
        }
        if let draft = annotationDraft, draft.bookID == currentID, !values.contains(where: { $0.id == draft.id }) { values.append(draft.annotation) }
        return values
    }
    var bookNotesIndex: BookNotesIndex {
        if let cachedNotesIndex { return cachedNotesIndex }
        var graph = currentBook?.graph ?? ReadingGraph()
        if !textNoteDrafts.isEmpty || annotationDraft != nil { graph.replaceAnnotations(graphAnnotations) }
        let result = BookNotesIndex(entries:chapters.map { .init(title:$0.title,href:$0.href,depth:$0.depth) },graph:graph)
        cachedNotesIndex = result
        recordNotesIndexBuild()
        return result
    }
    func noteForEditing(_ annotation: ReaderAnnotation, bookID: UUID) -> ReaderAnnotation {
        let saved = textNoteDrafts.first { $0.bookID == bookID && $0.id == annotation.id }
            ?? textNoteDrafts.first { $0.bookID == bookID && annotation.selectionLocator != nil && $0.annotation.selectionLocator == annotation.selectionLocator && ($0.annotation.intent ?? .thought) == (annotation.intent ?? .thought) && $0.annotation.responseToID == annotation.responseToID }
        let committed = books.first(where:{ $0.id == bookID })?.annotations?.first(where:{ $0.id == annotation.id })
        let latest = committed.flatMap { $0.updatedAt > annotation.updatedAt ? $0 : nil } ?? annotation
        var value = saved?.annotation ?? latest
        value.title = value.discussionLabel(value.title)
        // A recovered draft is authoritative, including an unfinished relation.
        if saved == nil, value.graphRelationDraft == nil, let book = books.first(where:{ $0.id == bookID }) {
            let live = Set((book.knowledgeEntities ?? []).filter { $0.deletedAt == nil }.map(\.id))
            value.graphRelationDraft = book.knowledgeRelations?.first {
                $0.deletedAt == nil && live.contains($0.sourceID) && live.contains($0.targetID) && $0.evidenceIDs.contains(value.id)
                    && Set(value.entityIDs ?? []).isSuperset(of:[$0.sourceID,$0.targetID])
            }
        }
        return value
    }
    func openNoteGraph(noteID: String? = nil) {
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return }
        #endif
        selectionDiscussion = nil; selectionEntity = nil
        selectedReadingItem = noteID.map { .node(.init(.note,$0)) }; discussionFocusMessage = nil
        graphNoteID = noteID; showNoteGraph = true
    }
    @discardableResult func openReadingChapter(_ id: Int) -> Bool {
        guard chapters.indices.contains(id), go(chapters[id].href) else { return false }
        readingControlsVisible = false
        return true
    }
    @discardableResult @MainActor func openKnowledgeWorkspace(bookID: UUID? = nil, noteID: String? = nil) -> Bool {
        guard !busy, !loading, !handwritingActive else { error = "请等当前操作完成，再打开脉络。"; return false }
        guard let id = bookID ?? currentID ?? visibleBooks.max(by:{ $0.lastRead < $1.lastRead })?.id else {
            error = "导入一本书后，就可以在脉络图中记录与整理。"; return false
        }
        guard books.contains(where:{ $0.id == id }) else { error = "这本图书已不在书库中，请刷新后重试。"; return false }
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return false }
        if let book = books.first(where:{ $0.id == id }), !isDownloaded(book) {
            guard knowledgeOpenTask == nil, downloadingBook == nil else { return false }
            knowledgeOpenTask = Task { @MainActor in
                defer { knowledgeOpenTask = nil }
                await openFromLibrary(id)
                guard !Task.isCancelled, currentID == id, error == nil else { return }
                selectionDiscussion = nil; selectionEntity = nil; graphNoteID = noteID; showNoteGraph = true
            }
            return true
        }
        #endif
        if currentID != id { open(id) }
        guard currentID == id else { return false }
        selectedReadingItem = noteID.map { .node(.init(.note,$0)) }; discussionFocusMessage = nil
        graphNoteID = noteID
        selectionDiscussion = nil; selectionEntity = nil; showNoteGraph = true
        return true
    }
    var currentNoteSectionID: Int? {
        bookNotesIndex.structure.sectionID(href:position?.chapterHref ?? position?.anchor?.href,title:position?.chapter ?? "")
    }
    func beginQuickNote() {
        pendingGraphNote = nil
        guard !loading, currentID != nil else { return }
        #if os(iOS)
        guard suspendInlineInkForNavigation() else { return }
        #endif
        guard let item = newGraphNote(chapterID:currentNoteSectionID) else { return }
        openNoteGraph(noteID:item.id)
    }
    func finishQuickNotePresentation() {
        guard let pending = pendingGraphNote else { return }
        pendingGraphNote = nil
        if currentID == pending.bookID { openNoteGraph(noteID:pending.noteID) }
    }

    @discardableResult func recordSelectedEntity(name: String, kind: BookEntityKind, source: ReaderAnnotation, bookID: UUID) -> UUID? {
        guard currentID == bookID else { error = "图书已切换，请在当前图书重新选择原文。"; return nil }
        guard !isNoteRemoved(source.id,bookID:bookID) else { error = "原文记录已移除，请恢复记录后再添加节点。"; return nil }
        var entityID: UUID?
        guard commitReadingGraph(bookID:bookID,{ graph in
            entityID = try graph.recordEntity(BookEntity(name:name,kind:kind),from:source)
        }) else { return nil }
        return entityID
    }

    @discardableResult func saveKnowledgeEntity(_ entity: BookEntity,bookID: UUID? = nil) -> UUID? {
        guard let target = bookID ?? currentID, let index = books.firstIndex(where: { $0.id == target }) else { return nil }
        var entity = entity
        if entity.progress == nil { entity.progress = currentID == target ? (position?.progress ?? books[index].progress) : books[index].progress }
        if entity.chapterHref == nil && currentID == target { entity.chapterHref = position?.chapterHref }
        entity.name = entity.name.trimmingCharacters(in:.whitespacesAndNewlines)
        entity.aliases = Array(Set(entity.aliases.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != entity.name })).sorted()
        guard (entity.note?.count ?? 0) <= 100_000 else { error = "节点内容过长，最多可保存十万字。"; return nil }
        guard !entity.name.isEmpty, entity.name.count <= 80, entity.aliases.count <= 30, entity.aliases.allSatisfy({ $0.count <= 80 }) else {
            error = "请填写简短的事物名称。"; return nil
        }
        var values = books[index].knowledgeEntities ?? []
        let names = Set(([entity.name] + entity.aliases).map { $0.lowercased() })
        if let duplicate = values.first(where: { $0.id != entity.id && $0.kind == entity.kind && !names.isDisjoint(with:([$0.name] + $0.aliases).map { $0.lowercased() }) }) {
            if !values.contains(where: { $0.id == entity.id }) {
                if duplicate.deletedAt == nil { return duplicate.id }
                entity = duplicate; entity.deletedAt = nil
            } else {
            error = "已有同名或同别名的\(entity.kind.title)：\(duplicate.name)。请使用已有卡片。"; return nil
            }
        }
        if let i = values.firstIndex(where: { $0.id == entity.id }) { values[i] = entity } else { values.append(entity) }
        guard commitReadingGraph(bookID:target,{ $0.replaceEntities(values) }) else { return nil }
        try? discardReadingNodeDraft(.init(.entity,entity.id.uuidString),bookID:target)
        return entity.id
    }

    /// Commit content and its evidence-backed connections in a single index write.
    @discardableResult func saveGraphAnnotation(_ annotation: ReaderAnnotation, bookID: UUID, relation: BookRelation?) -> Bool {
        guard bookID == currentID else { return false }
        return persistGraphAnnotation(annotation,bookID:bookID,relation:relation,allowEmptyExisting:false)
    }

    /// An editor may disappear after the reader switches books. Flush to its
    /// original book, without publishing its marks into the new reading canvas.
    @discardableResult func autosaveGraphAnnotation(_ annotation: ReaderAnnotation, bookID: UUID, relation: BookRelation?) -> Bool {
        guard let book = books.first(where:{ $0.id == bookID }) else {
            error = "原图书已移除，修改仍保留在编辑器中。"; return false
        }
        guard !isNoteRemoved(annotation.id,bookID:bookID) else {
            error = "这条笔记已移到最近删除，请恢复后再编辑。"; return false
        }
        let empty = annotation.quote.isEmpty && annotation.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && (annotation.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && (annotation.attributes ?? ReadingNodeAttributes()) == ReadingNodeAttributes()
            && (annotation.discussion?.messages.isEmpty ?? true) && (annotation.discussion?.composer.isEmpty ?? true)
        if empty && !(book.annotations ?? []).contains(where:{ $0.id == annotation.id }) {
            do {
                if let id = UUID(uuidString:annotation.id) { try discardNoteDraft(bookID:bookID,id:id,ink:false) }
                return true // Opening an empty editor must not create an empty note.
            } catch { self.error = "空白笔记草稿暂时未能清理，请重试。"; return false }
        }
        return persistGraphAnnotation(annotation,bookID:bookID,relation:relation,allowEmptyExisting:true)
    }

    private func persistGraphAnnotation(_ annotation: ReaderAnnotation, bookID: UUID, relation: BookRelation?, allowEmptyExisting: Bool) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return false }
        var item = annotation
        item.graphRelationDraft = nil
        item.title = item.title?.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (item.title?.count ?? 0) <= 160, item.note.count <= 100_000,
              !item.quote.isEmpty || !item.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !(item.title ?? "").isEmpty || !(item.discussion?.messages.isEmpty ?? true)
                || (item.attributes ?? ReadingNodeAttributes()) != ReadingNodeAttributes()
                || (allowEmptyExisting && (!(item.discussion?.composer.isEmpty ?? true) || (books[index].annotations ?? []).contains(where:{ $0.id == item.id }))) else {
            error = "先写下一点想法，再保存笔记。"; return false
        }
        if let responseID = item.responseToID {
            guard responseID != item.id, books[index].annotations?.contains(where: { $0.id == responseID && $0.intent == .question }) == true else {
                error = "原疑问已移除，请先恢复疑问再保存回应。"; return false
            }
        }
        let knownEntities = Set((books[index].knowledgeEntities ?? []).map(\.id))
        let entities = Set((books[index].knowledgeEntities ?? []).filter { $0.deletedAt == nil }.map(\.id))
        item.entityIDs = Array(Set(item.entityIDs ?? [])).filter { knownEntities.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        var annotations = books[index].annotations ?? []
        if let i = annotations.firstIndex(where: { $0.id == item.id }) ?? annotations.firstIndex(where: { item.selectionLocator != nil && $0.selectionLocator == item.selectionLocator && ($0.intent ?? .thought) == (item.intent ?? .thought) && $0.responseToID == item.responseToID }) {
            item.id = annotations[i].id; item.createdAt = annotations[i].createdAt; item.updatedAt = Date(); annotations[i] = item
        } else { item.updatedAt = Date(); annotations.append(item) }
        var relations = books[index].knowledgeRelations ?? []
        if var relation {
            relation.label = relation.label.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !relation.label.isEmpty, relation.label.count <= 60, relation.sourceID != relation.targetID,
                  entities.isSuperset(of:[relation.sourceID,relation.targetID]),
                  Set(item.entityIDs ?? []).isSuperset(of:[relation.sourceID,relation.targetID]) else {
                error = "请选择两个不同的关联，并填写关系，例如「师父」「属于」或「反驳」。"; return false
            }
            relation.standalone = true
            relation.progress = relation.progress ?? item.progress; relation.chapterHref = relation.chapterHref ?? item.chapterHref
            if let i = relations.firstIndex(where: { $0.id == relation.id && $0.deletedAt == nil }) ?? relations.firstIndex(where: { $0.deletedAt == nil && $0.sourceID == relation.sourceID && $0.targetID == relation.targetID && $0.label == relation.label && $0.conjecture == relation.conjecture }) {
                relations[i].evidenceIDs = Array(Set(relations[i].evidenceIDs + [item.id])).sorted()
                relations[i].sourceID = relation.sourceID; relations[i].targetID = relation.targetID; relations[i].label = relation.label
                relations[i].conjecture = relation.conjecture; relations[i].standalone = true
                relations[i].progress = min(relations[i].progress ?? item.progress,item.progress)
                relations[i].chapterHref = relations[i].chapterHref ?? item.chapterHref
            } else { relation.evidenceIDs = [item.id]; relations.append(relation) }
        }
        guard commitReadingGraph(bookID:bookID,{ $0.replaceAnnotations(annotations); $0.replaceRelations(relations) }) else { return false }
        if let id = UUID(uuidString:annotation.id) { try? discardNoteDraft(bookID:bookID,id:id,ink:false) }
        if annotationDraft?.bookID == bookID && annotationDraft?.id == annotation.id { annotationDraft = nil }
        return true
    }

    /// Resolve both endpoints and save the event, its optional note and edge in
    /// one write. Canceling or a failed write cannot leave half an event behind.
    func saveReadingEvent(source: BookEntity, target: BookEntity, action: String, note: String,
                          sourceNode: ReadingNodeID? = nil, targetNode: ReadingNodeID? = nil, bookID: UUID) -> ReadingEdge.ID? {
        guard currentID == bookID, let book = books.first(where:{ $0.id == bookID }) else {
            error = "图书已切换，请返回原图书添加事件。"; return nil
        }
        let label = action.trimmingCharacters(in:.whitespacesAndNewlines)
        let text = note.trimmingCharacters(in:.whitespacesAndNewlines)
        let progress = position?.progress ?? book.progress
        guard !label.isEmpty, label.count <= 60, text.count <= 100_000,
              progress.isFinite, (0...1).contains(progress) else {
            error = "请填写事件动作，最多 60 个字。"; return nil
        }
        var result: ReadingEdge.ID?
        guard commitReadingGraph(bookID:bookID,{ graph in
            var entities = graph.entities
            func resolve(_ proposed: BookEntity, existing: ReadingNodeID?) throws -> ReadingNodeID {
                if let existing {
                    guard [.entity,.note,.ink,.discussion].contains(existing.kind),
                          let node = graph.node(existing), node.deletedAt == nil else { throw ReadingGraphError.missingEndpoint }
                    return existing
                }
                let name = proposed.name.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 80 else { throw ReadingGraphError.invalidIdentity }
                var entity = entities.first(where:{ $0.id == proposed.id })
                    ?? entities.first(where:{ $0.kind == proposed.kind && ([$0.name] + $0.aliases).contains { $0.caseInsensitiveCompare(name) == .orderedSame } })
                    ?? BookEntity(id:proposed.id,name:name,kind:proposed.kind)
                entity.deletedAt = nil
                entity.progress = min(entity.progress ?? progress,progress)
                entity.chapterHref = entity.chapterHref ?? position?.chapterHref
                if let i = entities.firstIndex(where:{ $0.id == entity.id }) { entities[i] = entity }
                else { entities.append(entity) }
                return .init(.entity,entity.id.uuidString)
            }
            let a = try resolve(source,existing:sourceNode), b = try resolve(target,existing:targetNode)
            guard a != b else { throw ReadingGraphError.invalidConnection }
            graph.replaceEntities(entities)
            var relations = graph.relations
            var relation: BookRelation?
            if a.kind == .entity, b.kind == .entity, let aid = UUID(uuidString:a.owner), let bid = UUID(uuidString:b.owner) {
                relation = relations.first(where:{ $0.deletedAt == nil && $0.sourceID == aid && $0.targetID == bid && $0.label == label && !$0.conjecture })
                    ?? BookRelation(sourceID:aid,targetID:bid,label:label,evidenceIDs:[])
                if var value = relation {
                    value.standalone = true
                    value.progress = min(value.progress ?? progress,progress)
                    value.chapterHref = value.chapterHref ?? position?.chapterHref
                    relation = value
                }
            }
            if !text.isEmpty {
                var annotations = graph.annotations
                let title = "\(graph.title(for:a) ?? source.name) · \(label) · \(graph.title(for:b) ?? target.name)"
                let existing = annotations.first { item in
                    guard item.note == text else { return false }
                    if let relation { return relation.evidenceIDs.contains(item.id) }
                    let id = ReadingNodeID(.note,item.id)
                    return item.title == title && [a,b].allSatisfy { target in
                        graph.searchEdges("").contains { $0.id.source == id && $0.id.target == target && $0.label == "事件依据" }
                    }
                }
                var evidence = existing ?? ReaderAnnotation(cfi:"",quote:"",chapter:position?.chapter ?? "阅读事件",progress:progress,note:text)
                evidence.title = title
                evidence.chapterHref = evidence.chapterHref ?? position?.chapterHref
                evidence.entityIDs = [a,b].filter { $0.kind == .entity }.compactMap { UUID(uuidString:$0.owner) }
                if let i = annotations.firstIndex(where:{ $0.id == evidence.id }) { annotations[i] = evidence }
                else { annotations.append(evidence) }
                graph.replaceAnnotations(annotations)
                if var value = relation {
                    value.evidenceIDs = Array(Set(value.evidenceIDs + [evidence.id])).sorted()
                    relation = value
                }
                else {
                    for endpoint in [a,b] where !graph.searchEdges("").contains(where:{ $0.id.source == .init(.note,evidence.id) && $0.id.target == endpoint && $0.label == "事件依据" }) {
                        try graph.apply(.connect(.init(kind:.association,source:.init(.note,evidence.id),target:endpoint,label:"事件依据",record:UUID())))
                    }
                }
            }
            if let relation {
                if let i = relations.firstIndex(where:{ $0.id == relation.id }) { relations[i] = relation }
                else { relations.append(relation) }
                graph.replaceRelations(relations)
                result = graph.edges.first(where:{ $0.relationship?.id == relation.id && $0.deletedAt == nil })?.id
            } else if let existing = graph.searchEdges("").first(where:{ $0.id.source == a && $0.id.target == b && $0.label == label }) {
                result = existing.id
            } else {
                let edge = ReadingEdge(kind:.association,source:a,target:b,label:label,record:UUID())
                try graph.apply(.connect(edge)); result = edge.id
            }
        }) else { return nil }
        return result
    }

    @discardableResult func saveIndependentRelation(_ value: BookRelation, draftID: UUID? = nil) -> UUID? {
        guard let index = books.firstIndex(where: { $0.id == currentID }) else { return nil }
        var value = value
        value.label = value.label.trimmingCharacters(in:.whitespacesAndNewlines)
        let entities = Set((books[index].knowledgeEntities ?? []).filter { $0.deletedAt == nil }.map(\.id))
        let live = Set((books[index].annotations ?? []).map(\.id) + (books[index].pageNotes ?? []).map { $0.id.uuidString })
        let removed = Set((books[index].removedNotes ?? []).compactMap { $0.annotation?.id ?? $0.pageNote?.id.uuidString })
        let existingEvidence = Set(books[index].knowledgeRelations?.first { $0.id == value.id }?.evidenceIDs ?? [])
        guard entities.contains(value.sourceID), entities.contains(value.targetID), value.sourceID != value.targetID,
              !value.label.isEmpty, value.label.count <= 60 else {
            error = "请选择两个事物，并填写关系。"; return nil
        }
        // Never silently drop a selected draft, or sever a recoverable source
        // when the reader edits a relation after moving its note to Recently Deleted.
        guard Set(value.evidenceIDs).isSubset(of:live.union(removed).union(existingEvidence)) else {
            error = "请先保存作为依据的笔记，再保存关系。未保存的内容仍在笔记草稿中。"; return nil
        }
        value.evidenceIDs = Array(Set(value.evidenceIDs)).sorted()
        value.standalone = true; value.deletedAt = nil
        value.progress = value.progress ?? position?.progress ?? currentBook?.progress ?? 0
        value.chapterHref = value.chapterHref ?? position?.chapterHref
        guard let progress = value.progress, progress.isFinite, (0...1).contains(progress) else { error = "阅读位置无效，请重新打开图书。"; return nil }
        var values = books[index].knowledgeRelations ?? []
        if let i = values.firstIndex(where: { $0.id == value.id }) { values[i] = value }
        else if let i = values.firstIndex(where: { $0.deletedAt == nil && $0.sourceID == value.sourceID && $0.targetID == value.targetID && $0.label == value.label && $0.conjecture == value.conjecture }) {
            value.id = values[i].id; value.evidenceIDs = Array(Set(values[i].evidenceIDs + value.evidenceIDs)).sorted()
            value.progress = min(values[i].progress ?? progress,progress); values[i] = value
        } else { values.append(value) }
        return commitReadingGraph(bookID:books[index].id) {
            $0.replaceRelations(values)
            if let draftID { $0.relationDrafts.removeAll { $0.id == draftID } }
        } ? value.id : nil
    }

    @discardableResult func keepRelationDraft(_ draft: BookRelationDraft, discard: Bool = false) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == currentID }) else { return false }
        guard discard || draft.label.count <= 60 else { error = "关系名称请控制在 60 字以内。"; return false }
        var values = books[index].relationDrafts ?? []
        values.removeAll { $0.id == draft.id }
        if !discard { values.append(draft) }
        return commitReadingGraph(bookID:books[index].id) { $0.relationDrafts = values }
    }

    @discardableResult func setRelationDeleted(_ id: UUID, deleted: Bool) -> Bool {
        guard let edge = currentBook?.graph.edges.first(where:{ $0.relationship?.id == id }) else { return false }
        return performReadingMutation(deleted ? .disconnect(edge.id) : .restoreConnection(edge.id))
    }

    @discardableResult func setKnowledgeEntityDeleted(_ id: UUID, deleted: Bool) -> Bool {
        guard performReadingMutation(deleted ? .remove(.init(.entity,id.uuidString)) : .restore(.init(.entity,id.uuidString))) else { return false }
        if deleted, let bookID = currentID { try? discardReadingNodeDraft(.init(.entity,id.uuidString),bookID:bookID) }
        return true
    }

    func respondToQuestion(_ id: String) -> ReaderAnnotation? {
        guard let bookID = currentID, currentAnnotations.contains(where: { $0.id == id && $0.intent == .question }), var item = newGraphNote(chapterID:nil) else { return nil }
        item.responseToID = id
        annotationDraft = ReaderAnnotationDraft(bookID:bookID,annotation:item)
        return item
    }

    @discardableResult func saveGraphInkMetadata(_ note: ReaderPageNote) -> Bool {
        guard let index = books.firstIndex(where: { $0.id == currentID }), let i = books[index].pageNotes?.firstIndex(where: { $0.id == note.id }) else { return false }
        var values = books[index].graph.pageNotes
        var latest=values[i]
        latest.attributes=note.attributes;latest.text=note.text;latest.entityIDs=note.entityIDs;latest.updatedAt=Date();values[i]=latest
        return commitReadingGraph(bookID:books[index].id) { $0.replacePageNotes(values) }
    }

    @MainActor func graphSource(locator: String, href: String) async throws -> String {
        if let nativeBookReader { return nativeBookReader.excerpt(at:locator.isEmpty ? href : locator) }
        let session = annotationSessionID
        let result = try await webView.callAsyncJavaScript("return await reader.sourceExcerpt(locator,href)",arguments:["locator":locator,"href":href],in:nil,contentWorld:.page)
        guard annotationSessionID == session, currentID != nil else { throw CancellationError() }
        return result as? String ?? ""
    }
    /// A branch is a real saved node and edge, even before its first edit.
    func addReadingBranch(from source: ReadingNodeID?,chapterID: Int?,discussion: Bool = false) -> ReadingNodeID? {
        guard let bookID = currentID else { return nil }
        let chapter = chapterID.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil }
        var note = ReaderAnnotation(cfi:"",quote:"",chapter:chapter?.title ?? self.position?.chapter ?? "阅读笔记",progress:self.position?.progress ?? 0)
        note.chapterHref = chapter?.href ?? self.position?.chapterHref
        note.title = discussion ? "AI 对话" : "新主题"
        if discussion { note.discussion = ReaderDiscussion() }
        let id = ReadingNodeID(discussion ? .discussion : .note,note.id)
        guard commitReadingGraph(bookID:bookID,{ graph in
            var notes = graph.annotations
            if let source, graph.node(source) == nil,
               let draft = graphAnnotations.first(where:{ $0.id == source.owner }), !draft.quote.isEmpty || !draft.note.isEmpty || !(draft.title ?? "").isEmpty {
                notes.append(draft); graph.replaceAnnotations(notes)
            }
            if let source {
                guard let node = graph.node(source), node.deletedAt == nil else { throw ReadingGraphError.missingEndpoint }
                if let original = notes.first(where:{ $0.id == source.owner }) {
                    note.chapter = original.chapter; note.chapterHref = original.chapterHref; note.progress = original.progress
                    note.sourceLocator = original.sourceLocator
                }
                if case .ink(let ink)=node.content {
                    note.chapter=ink.anchor.chapter;note.chapterHref=ink.anchor.chapterHref;note.progress=ink.anchor.progress
                    if discussion {
                        let locator = ink.inkParts.first?.sources.first?.id ?? ink.anchor.locator
                        if currentBook?.format == .pdf { note.sourceLocator = locator }
                        else { note.cfi = locator }
                        note.quote=ink.excerpt
                        note.note=ink.text ?? ""
                        note.title=String(ink.displayTitle.prefix(160))
                    }
                }
                if case .entity(let entity) = node.content {
                    note.entityIDs = [entity.id]
                    if discussion {
                        note.note = entity.note ?? ""
                        note.title = entity.name
                        note.progress = noteVisibilityProgress
                        note.chapterHref = entity.chapterHref ?? note.chapterHref
                        note.chapter = chapters.first { $0.href == note.chapterHref }?.title ?? note.chapter
                    }
                }
            }
            notes.append(note); graph.replaceAnnotations(notes)
            if let source { try graph.apply(.connect(.init(kind:.association,source:source,target:id,label:discussion ? "AI 对话" : "子主题",record:UUID()))) }
        }) else { return nil }
        graphNoteID = note.id
        selectReadingItem(.node(id))
        return id
    }
    func discussionContentOwner(_ noteID: String,bookID: UUID) -> ReadingNode? {
        guard let graph = books.first(where:{ $0.id == bookID })?.graph else { return nil }
        let thread = ReadingNodeID(.discussion,noteID)
        guard let edge = graph.edges.first(where:{
            $0.id.kind == .association && $0.label == "AI 对话" && $0.id.target == thread
                && [.entity,.ink].contains($0.id.source.kind) && $0.deletedAt == nil
                && graph.node($0.id.source)?.deletedAt == nil
        }) else { return nil }
        return graph.node(edge.id.source)
    }

    func beginReadingNodeDiscussion(_ id: ReadingNodeID) -> ReadingNodeID? {
        guard let bookID = currentID else { return nil }
        if [.note,.discussion].contains(id.kind), let note = graphAnnotations.first(where:{ $0.id == id.owner }) {
            return openReadingDiscussion(noteForEditing(note,bookID:bookID),bookID:bookID)
        }
        if let graph = currentBook?.graph,
           let thread = graph.edges.first(where:{ $0.id.kind == .association && $0.id.source == id
               && $0.id.target.kind == .discussion && $0.label == "AI 对话" && $0.deletedAt == nil
               && graph.node($0.id.target).map { $0.deletedAt == nil } == true })?.id.target {
            selectReadingItem(.node(thread)); return thread
        }
        return addReadingBranch(from:id,chapterID:currentNoteSectionID,discussion:true)
    }

    func beginReadingNodeDiscussion(chapter: ChapterItem?) -> ReadingNodeID? {
        guard let bookID = currentID, !loading else { return nil }
        let scope = chapter?.discussionScope ?? ReaderDiscussion.bookScope
        let chapterTitle = chapter?.title ?? "全书"
        let existing = graphAnnotations.first { $0.discussionScope == scope }
        var note = existing.map { noteForEditing($0,bookID:bookID) }
            ?? ReaderAnnotation(cfi:"",quote:"",chapter:chapterTitle,progress:0)
        note.discussionScope = scope
        note.title = note.discussionLabel(note.title) ?? ReaderDiscussion.defaultTitle
        note.chapter = chapterTitle
        note.chapterHref = chapter?.href
        return openReadingDiscussion(note,bookID:bookID)
    }

    private func openReadingDiscussion(_ original: ReaderAnnotation,bookID: UUID) -> ReadingNodeID? {
        var note = original
        if note.discussion == nil { note.discussion = ReaderDiscussion() }
        if !currentAnnotations.contains(note), !autosaveGraphAnnotation(note,bookID:bookID,relation:note.graphRelationDraft) { return nil }
        let target = ReadingNodeID(.discussion,note.id)
        selectReadingItem(.node(target))
        return target
    }

    func newGraphNote(chapterID: Int?) -> ReaderAnnotation? {
        guard let bookID = currentID else { return nil }
        let chapter = chapterID.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil }
        var item = ReaderAnnotation(cfi:"",quote:"",chapter:chapter?.title ?? position?.chapter ?? "阅读笔记",progress:position?.progress ?? 0)
        item.chapterHref = chapter?.href ?? position?.chapterHref
        if nativeBookReader != nil, chapterID == currentNoteSectionID, let position {
            item.sourceLocator = position.locator
        }
        if let chapterID, chapterID != currentNoteSectionID, !chapters.isEmpty { item.progress = Double(chapterID) / Double(chapters.count) }
        annotationDraft = ReaderAnnotationDraft(bookID:bookID,annotation:item); graphNoteID = item.id
        return item
    }
}
