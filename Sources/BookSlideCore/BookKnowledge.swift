import Foundation

public struct BookGraphNote: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var quote: String
    public var text: String
    public var chapter: String
    public var chapterID: Int?
    public var locator: String
    public var progress: Double
    public var entityIDs: [UUID]
    public var ink: Bool
    public var question: Bool = false
    public var resolved: Bool = false
    public var responseToID: String? = nil
    public var personalText: String? = nil
    /// An excerpt retained only as an entity's provenance, not a second thought.
    public var entitySourceOnly: Bool = false
    public var showsOnCanvas: Bool { !highlightOnly && !entitySourceOnly }
    public var highlightOnly: Bool {
        !ink && !question && responseToID == nil && text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && entityIDs.isEmpty
    }
}
public struct BookGraphDiscussion: Identifiable, Equatable {
    public var id: ReadingNodeID
    public var noteID: String
    public var title: String
    public var preview: String
    public var messageCount: Int
    public var progress: Double
}

/// Builds a view of existing source notes, rather than copying them into a
/// second graph database. Legacy ambiguous chapter names stay unassigned.
public struct BookNotesIndex {
    public let graph: ReadingGraph
    public let structure: BookStructure
    public let notes: [BookGraphNote]
    public let entities: [BookEntity]
    public let relations: [BookRelation]
    public let discussions: [BookGraphDiscussion]
    public let associations: [ReadingEdge]
    public init(entries: [BookStructure.Entry], graph: ReadingGraph) {
        self.init(entries:entries,annotations:graph.annotations,pageNotes:graph.pageNotes,entities:graph.entities,relations:graph.relations,graph:graph)
    }
    public init(entries: [BookStructure.Entry], annotations: [ReaderAnnotation], pageNotes: [ReaderPageNote], entities: [BookEntity], relations: [BookRelation], graph: ReadingGraph? = nil) {
        let readingGraph = graph ?? ReadingGraph(annotations:annotations,pageNotes:pageNotes,entities:entities,relations:relations)
        self.graph = readingGraph
        let liveNodes = Set(readingGraph.nodes.filter { $0.deletedAt == nil }.map(\.id))
        associations = readingGraph.edges.filter { $0.id.kind == .association && $0.deletedAt == nil && liveNodes.contains($0.id.source) && liveNodes.contains($0.id.target) }
        let structure = BookStructure(entries:entries); self.structure = structure; self.entities = entities.filter { $0.deletedAt == nil }
        func chapterID(href: String?, title: String) -> Int? {
            structure.sectionID(href:href,title:title)
        }
        // Keep explicitly connected records visible even when they have no text.
        let connectedOwners = Set(readingGraph.edges.filter {
            $0.deletedAt == nil && liveNodes.contains($0.id.source) && liveNodes.contains($0.id.target)
                && [.association,.responds].contains($0.id.kind)
        }.flatMap { [$0.id.source.owner,$0.id.target.owner] })
        let evidenceIDs = Set(relations.filter { $0.deletedAt == nil }.flatMap(\.evidenceIDs))
        var values = annotations.map { item in
            let transcript = item.discussion?.markdown ?? ""
            let text = [item.note,transcript].filter { !$0.isEmpty }.joined(separator:"\n\n")
            var note = BookGraphNote(id:item.id,title:Self.noteTitle(item.title,text:item.note.isEmpty ? (item.discussion?.messages.first?.text ?? "") : item.note,quote:item.quote),quote:item.quote,text:text,
                          chapter:item.chapter,chapterID:chapterID(href:item.chapterHref,title:item.chapter),locator:item.readingLocator,
                          progress:item.progress,entityIDs:item.entityIDs ?? [],ink:false)
            note.question = item.intent == .question; note.resolved = item.questionResolved == true; note.responseToID = item.responseToID
            note.personalText = item.note
            // Derive this for old libraries too; never delete the source or its
            // links. A later note, question or discussion makes it visible again.
            note.entitySourceOnly = !(item.entityIDs?.isEmpty ?? true) && item.selectionLocator != nil && !item.quote.isEmpty
                && item.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                && (item.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                && item.intent == nil && item.responseToID == nil && item.discussion == nil && item.graphRelationDraft == nil
                && !connectedOwners.contains(item.id) && !evidenceIDs.contains(item.id)
            return note
        }
        values += pageNotes.map { item in
            BookGraphNote(id:item.id.uuidString,title:item.displayTitle,quote:item.excerpt,text:item.text ?? "",chapter:item.anchor.chapter,
                          chapterID:chapterID(href:item.anchor.chapterHref,title:item.anchor.chapter),locator:item.anchor.locator,
                          progress:item.anchor.progress,entityIDs:item.entityIDs ?? [],ink:true)
        }
        notes = values.sorted { $0.progress == $1.progress ? $0.id < $1.id : $0.progress < $1.progress }
        let live = Set(values.map(\.id)), entityIDs = Set(self.entities.map(\.id))
        self.relations = relations.filter { $0.deletedAt == nil && entityIDs.contains($0.sourceID) && entityIDs.contains($0.targetID) && ($0.standalone == true || !$0.evidenceIDs.allSatisfy { !live.contains($0) }) }
        self.discussions = annotations.compactMap { note in
            guard let discussion = note.discussion else { return nil }
            let title = discussion.title
            let preview = discussion.messages.last(where:{ $0.role == .assistant })?.text ?? discussion.composer
            return .init(id:.init(.discussion,note.id),noteID:note.id,title:String(title.prefix(40)),preview:String(preview.prefix(140)),messageCount:discussion.messages.count,progress:note.progress)
        }
    }
    public static func normalized(_ href: String) -> String {
        let value = href.removingPercentEncoding ?? href
        return value.hasPrefix("./") ? String(value.dropFirst(2)) : value
    }
    public static func noteTitle(_ title: String?, text: String, quote: String) -> String {
        let explicit = title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        let content = text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? quote : text
        let first = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "阅读笔记"
        return String(first.prefix(24))
    }
    public func notes(in chapterID: Int?) -> [BookGraphNote] {
        guard let chapterID else { return notes.filter { $0.chapterID == nil } }
        return notes.filter { note in
            guard let id = note.chapterID else { return false }
            return id == chapterID || structure.ancestors(of:id).contains(chapterID)
        }
    }
    public func search(_ query: String) -> [BookGraphNote] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        let ids = Set(entities.filter { $0.matches(query) }.map(\.id))
        return notes.filter { [$0.title,$0.quote,$0.text,$0.chapter].contains(where:{ $0.localizedCaseInsensitiveContains(query) }) || !$0.entityIDs.allSatisfy { !ids.contains($0) } }
    }
    public func searchNodes(_ query: String, through progress: Double, includeFuture: Bool = false) -> [ReadingNode] {
        let noteIDs = Set(visibleNotes(through:progress,includeFuture:includeFuture).map(\.id))
        let entityIDs = Set(matchingEntities(through:progress,includeFuture:includeFuture).map { $0.id.uuidString })
        return graph.search(query).filter { node in node.id.kind == .entity ? entityIDs.contains(node.id.owner) : noteIDs.contains(node.id.owner) }
    }
    /// Suggestions use existing cards and aliases; the reader chooses what to link.
    public func suggestedEntities(for annotation: ReaderAnnotation, through progress: Double) -> [BookEntity] {
        let content = [annotation.title ?? "", annotation.quote, annotation.note].joined(separator:"\n")
        let linked = Set(annotation.entityIDs ?? [])
        return entities.filter { entity in
            !linked.contains(entity.id) && (entity.progress ?? 0) <= progress + 0.0001 &&
            ([entity.name] + entity.aliases).contains { name in
                !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && content.localizedCaseInsensitiveContains(name)
            }
        }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func relatedNotes(for annotation: ReaderAnnotation, through progress: Double) -> [BookGraphNote] {
        let linked = Set(annotation.entityIDs ?? []).intersection(entities.map(\.id))
        let mentioned = Set(suggestedEntities(for:annotation,through:progress).map(\.id))
        let subjects = linked.union(mentioned)
        let chapterIDs = structure.nodes.indices.filter { id in
            if let href = annotation.chapterHref, !href.isEmpty { return Self.normalized(structure.nodes[id].entry.href) == Self.normalized(href) }
            return structure.nodes[id].entry.title == annotation.chapter
        }
        func sameChapter(_ note: BookGraphNote) -> Bool {
            chapterIDs.count == 1 && note.chapterID == chapterIDs.first
        }
        func shared(_ note: BookGraphNote) -> Int { subjects.intersection(note.entityIDs).count }
        return visibleNotes(through:progress).filter {
            $0.id != annotation.id && (shared($0) > 0 || sameChapter($0) || $0.id == annotation.responseToID || $0.responseToID == annotation.id)
        }.sorted {
            if shared($0) != shared($1) { return shared($0) > shared($1) }
            if sameChapter($0) != sameChapter($1) { return sameChapter($0) }
            let a = abs($0.progress - annotation.progress), b = abs($1.progress - annotation.progress)
            return a == b ? $0.id < $1.id : a < b
        }
    }
    public func visibleRelations(through progress: Double, includeFuture: Bool = false) -> [BookRelation] {
        let ids = Set(notes.filter { includeFuture || $0.progress <= progress + 0.0001 }.map(\.id))
        return relations.filter {
            if $0.standalone == true { return includeFuture || ($0.progress ?? 1) <= progress + 0.0001 }
            return !$0.evidenceIDs.allSatisfy { !ids.contains($0) }
        }
    }
    public func visibleNotes(through progress: Double, includeFuture: Bool = false) -> [BookGraphNote] {
        notes.filter { includeFuture || $0.progress <= progress + 0.0001 }
    }
    public func matchingEntities(_ query: String = "", kind: BookEntityKind? = nil, through progress: Double, includeFuture: Bool = false) -> [BookEntity] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return entities.filter {
            (kind == nil || $0.kind == kind) && (includeFuture || ($0.progress ?? 0) <= progress + 0.0001)
                && (query.isEmpty || $0.matches(query))
        }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Independent relationships are searchable even before they have evidence.
    public func matchingRelations(_ query: String = "", kind: BookEntityKind? = nil, through progress: Double, includeFuture: Bool = false) -> [BookRelation] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let byID = Dictionary(grouping:entities,by:\.id).mapValues { $0[0] }
        return visibleRelations(through:progress,includeFuture:includeFuture).filter { relation in
            let endpoints = [byID[relation.sourceID],byID[relation.targetID]].compactMap { $0 }
            return (kind == nil || endpoints.contains { $0.kind == kind })
                && (query.isEmpty || relation.label.localizedCaseInsensitiveContains(query) || endpoints.contains { $0.matches(query) })
        }
    }
    public func openQuestions(through progress: Double) -> [BookGraphNote] {
        visibleNotes(through:progress).filter { $0.question && !$0.resolved }
    }
}
