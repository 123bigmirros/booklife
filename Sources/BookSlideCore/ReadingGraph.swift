import Foundation
import CryptoKit

/// One identity space for the reader's content. Message/source IDs are scoped
/// to their owning note, so imported conversations cannot collide.
public struct ReadingNodeID: Codable, Hashable {
    public enum Kind: String, Codable { case note, entity, ink, discussion, message, source }
    public var kind: Kind
    public var owner: String
    public var local: String?
    public init(_ kind: Kind, _ owner: String, local: String? = nil) { self.kind = kind; self.owner = owner; self.local = local }
}

/// Persisted view state for the embedded mind-map engine. Content stays in nodes/edges.
public struct ReadingCanvasNodeState: Codable, Equatable {
    public var id: String
    public var nodeID: ReadingNodeID?
    public var parent: String?
    public var order: Int
    public var expanded: Bool
    public var direction: Int?
    public var label: String?
    public init(id: String,nodeID: ReadingNodeID? = nil,parent: String?,order: Int,expanded: Bool = true,direction: Int? = nil,label: String? = nil) {
        self.id = id; self.nodeID = nodeID; self.parent = parent; self.order = order; self.expanded = expanded; self.direction = direction; self.label = label
    }
}

public struct ReadingNodeDraft: Codable, Equatable, Identifiable {
    public var bookID: UUID
    public var node: ReadingNode
    public var updatedAt: Date
    public var id: ReadingNodeID { node.id }
    public init(bookID: UUID, node: ReadingNode) { self.bookID = bookID; self.node = node; updatedAt = Date() }
}

/// Drafts use the same node envelope, outside the index transaction so a
/// temporarily unwritable index does not discard an editor's latest input.
public struct ReadingNodeDraftStore {
    public let directory: URL
    public init(libraryDirectory: URL) { directory = libraryDirectory.appendingPathComponent("NodeDrafts",isDirectory:true) }
    private func folder(_ bookID: UUID) -> URL { directory.appendingPathComponent(bookID.uuidString,isDirectory:true) }
    private func file(_ bookID: UUID,_ id: ReadingNodeID) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data:try encoder.encode(id)).map { String(format:"%02x",$0) }.joined()
        return folder(bookID).appendingPathComponent(key+".json")
    }
    public func save(_ draft: ReadingNodeDraft) throws {
        let data = try JSONEncoder().encode(draft)
        guard data.count <= 64*1024*1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at:folder(draft.bookID),withIntermediateDirectories:true)
        try data.write(to:file(draft.bookID,draft.id),options:.atomic)
    }
    public func load(bookID: UUID,id: ReadingNodeID) throws -> ReadingNodeDraft? {
        let url = try file(bookID,id)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let draft = try JSONDecoder().decode(ReadingNodeDraft.self,from:Data(contentsOf:url))
        guard draft.bookID == bookID && draft.id == id else { throw ReadingGraphError.invalidIdentity }
        return draft
    }
    public func drafts(bookID: UUID) throws -> [ReadingNodeDraft] {
        let folder = folder(bookID)
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }.map {
            let draft = try JSONDecoder().decode(ReadingNodeDraft.self,from:Data(contentsOf:$0))
            guard draft.bookID == bookID else { throw ReadingGraphError.invalidIdentity }; return draft
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func remove(bookID: UUID,id: ReadingNodeID) throws {
        let url = try file(bookID,id)
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
}

public struct ReadingGraphAnnotation: Codable, Equatable {
    public var value: ReaderAnnotation
    public var hadEntityList: Bool
    public init(value: ReaderAnnotation, hadEntityList: Bool = false) { self.value = value; self.hadEntityList = hadEntityList }
}
public struct ReadingGraphMessage: Codable, Equatable {
    public var value: ReaderDiscussionMessage
    public var omittedTurns: Int?
    public init(value: ReaderDiscussionMessage, omittedTurns: Int? = nil) { self.value = value; self.omittedTurns = omittedTurns }
}
public enum ReadingNodeContent: Codable, Equatable {
    case note(ReadingGraphAnnotation), entity(BookEntity), ink(ReaderPageNote)
    case discussion(ReaderDiscussion), message(ReadingGraphMessage), source(ReaderDiscussionSource)
    public var kind: ReadingNodeID.Kind {
        switch self {
        case .note: return .note; case .entity: return .entity; case .ink: return .ink
        case .discussion: return .discussion; case .message: return .message; case .source: return .source
        }
    }
}
public struct ReadingNode: Codable, Equatable, Identifiable {
    public var id: ReadingNodeID
    public var content: ReadingNodeContent
    public var deletedAt: Date?
    public init(id: ReadingNodeID, content: ReadingNodeContent, deletedAt: Date? = nil) {
        self.id = id; self.content = content; self.deletedAt = deletedAt
    }
    public var title: String {
        switch content {
        case .note(let value): return value.value.attributes?.name ?? BookNotesIndex.noteTitle(value.value.discussionLabel(value.value.title),text:value.value.note,quote:"")
        case .entity(let value): return value.name
        case .ink(let value): return value.attributes?.name ?? value.displayTitle
        case .discussion(let value): return value.title
        case .message(let value): return value.value.role == .user ? "我的问题" : "AI 回答"
        case .source(let value): return value.label
        }
    }
    public var text: String {
        switch content {
        case .note(let value): return ([value.value.note] + (value.value.attributes?.aliases ?? [])).filter { !$0.isEmpty }.joined(separator:" · ")
        case .entity(let value): return ([value.name] + value.aliases + [value.note].compactMap { $0 }).joined(separator:" · ")
        case .ink(let value): return ([value.excerpt,value.text ?? ""] + (value.attributes?.aliases ?? [])).joined(separator:"\n")
        case .discussion(let value): return value.composer
        case .message(let value): return value.value.text
        case .source(let value): return value.text
        }
    }
}
public struct ReadingRelationship: Codable, Equatable {
    public var id: UUID
    public var conjecture: Bool
    public var standalone: Bool?
    public var chapterHref: String?
    public var progress: Double?
    public var evidence: [String]
}
public struct ReadingEdge: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case mentions, quotes, discusses, contains, responds, cites, relationship, association }
    public struct ID: Codable, Hashable {
        public var kind: Kind
        public var source: ReadingNodeID
        public var target: ReadingNodeID
        public var record: UUID?
    }
    public var id: ID
    public var label: String
    public var order: Int
    public var relationship: ReadingRelationship?
    public var deletedAt: Date?
    public init(kind: Kind, source: ReadingNodeID, target: ReadingNodeID, label: String, order: Int = 0, record: UUID? = nil) {
        id = ID(kind:kind,source:source,target:target,record:record); self.label = label; self.order = order
    }
}
public enum ReadingGraphMutation {
    case upsert(ReadingNode), connect(ReadingEdge), remove(ReadingNodeID), restore(ReadingNodeID)
    case disconnect(ReadingEdge.ID), restoreConnection(ReadingEdge.ID)
}
public enum ReadingGraphSelection: Codable, Equatable, Hashable {
    case node(ReadingNodeID), edge(ReadingEdge.ID)
}
public enum ReadingGraphError: Error, LocalizedError {
    case unsupportedVersion, invalidIdentity, missingEndpoint, invalidConnection
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "这份阅读图由更新版本创建，请先更新应用。"
        case .invalidIdentity: return "阅读图中的节点标识不完整或重复，原文件已保留。"
        case .missingEndpoint: return "连接的节点已移除，请恢复后再试。"
        case .invalidConnection: return "请选择两个不同的节点，并填写简短的关系名称。"
        }
    }
}

/// The authoritative, versioned store. Typed arrays below are cached adapters
/// for existing editors; they are never encoded as a second source of truth.
public struct ReadingGraph: Codable, Equatable {
    /// Record an entity from a reader-selected passage in the same graph
    /// transaction as its source record. Existing notes and conversations win
    /// over a stale selection snapshot; recording the same name is idempotent.
    @discardableResult public mutating func recordEntity(_ proposed: BookEntity, from selection: ReaderAnnotation) throws -> UUID {
        let name = proposed.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, let locator = selection.selectionLocator,
              (locator.hasPrefix("epubcfi(") && locator.hasSuffix(")")) || PDFTextLocator.decode(locator) != nil,
              !selection.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, selection.quote.count <= 100_000,
              selection.progress.isFinite, (0...1).contains(selection.progress) else { throw ReadingGraphError.invalidIdentity }
        var updated = self
        var entity = entities.first { $0.kind == proposed.kind && ([$0.name] + $0.aliases).contains { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? proposed
        entity.name = entity.id == proposed.id ? name : entity.name
        entity.deletedAt = nil
        entity.chapterHref = entity.chapterHref ?? selection.chapterHref
        entity.progress = min(entity.progress ?? selection.progress,selection.progress)
        var allEntities = entities
        if let index = allEntities.firstIndex(where:{ $0.id == entity.id }) { allEntities[index] = entity } else { allEntities.append(entity) }
        var notes = annotations
        let existing = notes.firstIndex { $0.id == selection.id } ?? notes.firstIndex { $0.selectionLocator == locator && $0.responseToID == nil }
        var note = existing.map { notes[$0] } ?? selection
        note.entityIDs = Array(Set((note.entityIDs ?? []) + [entity.id])).sorted { $0.uuidString < $1.uuidString }
        if let existing { notes[existing] = note } else { notes.append(note) }
        updated.replaceEntities(allEntities)
        updated.replaceAnnotations(notes)
        self = updated
        return entity.id
    }
    public private(set) var nodes: [ReadingNode] = []
    public private(set) var edges: [ReadingEdge] = []
    public var removals: [ReaderRemovedNote] = []
    public var relationDrafts: [BookRelationDraft] = []
    public var canvasNodes: [ReadingCanvasNodeState] = []
    private var noteCache: [ReaderAnnotation] = []
    private var entityCache: [BookEntity] = []
    private var inkCache: [ReaderPageNote] = []
    private var relationCache: [BookRelation] = []
    public var annotations: [ReaderAnnotation] { noteCache }
    public var entities: [BookEntity] { entityCache }
    public var pageNotes: [ReaderPageNote] { inkCache }
    public var relations: [BookRelation] { relationCache }
    public init(annotations: [ReaderAnnotation] = [], pageNotes: [ReaderPageNote] = [], entities: [BookEntity] = [], relations: [BookRelation] = []) {
        replaceEntities(entities); replaceAnnotations(annotations); replacePageNotes(pageNotes); replaceRelations(relations)
    }
    private enum CodingKeys: String, CodingKey { case version, nodes, edges, removals, relationDrafts, canvasNodes, readingDiscussions }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy:CodingKeys.self)
        guard try box.decode(Int.self,forKey:.version) == 1 else { throw ReadingGraphError.unsupportedVersion }
        nodes = try box.decode([ReadingNode].self,forKey:.nodes); edges = try box.decode([ReadingEdge].self,forKey:.edges)
        removals = try box.decodeIfPresent([ReaderRemovedNote].self,forKey:.removals) ?? []
        relationDrafts = try box.decodeIfPresent([BookRelationDraft].self,forKey:.relationDrafts) ?? []
        canvasNodes = try box.decodeIfPresent([ReadingCanvasNodeState].self,forKey:.canvasNodes) ?? []
        try validate()
        rebuild()
        if let previous = try box.decodeIfPresent([String:ReaderDiscussion].self,forKey:.readingDiscussions), !previous.isEmpty {
            migrateReadingDiscussions(previous)
            try validate()
        }
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var box = encoder.container(keyedBy:CodingKeys.self)
        try box.encode(1,forKey:.version); try box.encode(nodes,forKey:.nodes); try box.encode(edges,forKey:.edges)
        if !removals.isEmpty { try box.encode(removals,forKey:.removals) }
        if !relationDrafts.isEmpty { try box.encode(relationDrafts,forKey:.relationDrafts) }
        if !canvasNodes.isEmpty { try box.encode(canvasNodes,forKey:.canvasNodes) }
    }
    public static func == (a: Self,b: Self) -> Bool {
        a.nodes == b.nodes && a.edges == b.edges && a.removals == b.removals && a.relationDrafts == b.relationDrafts && a.canvasNodes == b.canvasNodes
    }
    private mutating func migrateReadingDiscussions(_ previous: [String:ReaderDiscussion]) {
        let existing = Set(nodes.compactMap { node -> String? in
            guard case .note(let stored) = node.content else { return nil }
            return stored.value.discussionScope
        })
        let notes = previous.keys.sorted().compactMap { key -> ReaderAnnotation? in
            guard !existing.contains(key), let thread = previous[key] else { return nil }
            let bytes = Array(SHA256.hash(data:Data("reading-discussion/\(key)".utf8)))
            let id = UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],(bytes[6] & 0x0f) | 0x50,bytes[7],
                (bytes[8] & 0x3f) | 0x80,bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            let label = thread.messages.reversed().lazy.compactMap { message in
                message.context?.sources.first { $0.id.hasPrefix("已读正文") }?.label
            }.first
            let wholeBook = key == ReaderDiscussion.bookScope
            let chapter = wholeBook ? "全书" : label ?? "章节"
            var item = ReaderAnnotation(id:id.uuidString,cfi:"",quote:"",chapter:chapter,progress:0,
                createdAt:thread.messages.first?.createdAt ?? .distantPast,updatedAt:thread.messages.last?.createdAt ?? .distantPast)
            item.title = ReaderDiscussion.defaultTitle
            item.discussionScope = key
            item.discussion = thread
            return item
        }
        if !notes.isEmpty { replaceAnnotations(annotations + notes) }
    }
    public func validate() throws {
        guard Set(nodes.map(\.id)).count == nodes.count, Set(edges.map(\.id)).count == edges.count else { throw ReadingGraphError.invalidIdentity }
        guard Set(canvasNodes.map(\.id)).count == canvasNodes.count,
              canvasNodes.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 512 && (0...10000).contains($0.order) && ($0.direction == nil || $0.direction == 0 || $0.direction == 1) }) else { throw ReadingGraphError.invalidIdentity }
        for node in nodes {
            guard node.id.kind == node.content.kind, !node.id.owner.isEmpty else { throw ReadingGraphError.invalidIdentity }
            let valid: Bool
            switch node.content {
            case .note(let stored):
                valid = stored.value.id == node.id.owner && stored.value.discussion == nil && stored.value.entityIDs == nil && stored.value.responseToID == nil && stored.value.quote.isEmpty
            case .entity(let value): valid = value.id.uuidString == node.id.owner && value.deletedAt == nil
            case .ink(let value): valid = value.id.uuidString == node.id.owner && (value.entityIDs?.isEmpty ?? true)
                && (value.parts == nil || (value.parts!.count<=1000 && !value.parts!.isEmpty && Set(value.parts!.map(\.id)).count==value.parts!.count && value.parts!.allSatisfy { $0.bounds.valid && $0.strokeIDs.count<=20000 && $0.anchor.viewportWidth>0 && $0.anchor.viewportHeight>0 }))
            case .discussion(let value): valid = value.messages.isEmpty
            case .message(let stored): valid = stored.value.id.uuidString == node.id.local && stored.value.context == nil
            case .source: valid = node.id.local != nil
            }
            guard valid else { throw ReadingGraphError.invalidIdentity }
        }
    }
    public func node(_ id: ReadingNodeID) -> ReadingNode? { nodes.first { $0.id == id } }
    private var discussionTitles: [String:String] {
        Dictionary(noteCache.compactMap { note in note.discussion.map { (note.id,$0.title) } },uniquingKeysWith:{ first,_ in first })
    }
    /// Discussion envelopes do not duplicate their child messages. Resolve the
    /// title through the graph's reconstructed, ordered conversation instead.
    public func title(for id: ReadingNodeID) -> String? {
        guard let node = node(id) else { return nil }
        if id.kind == .discussion { return noteCache.first { $0.id == id.owner }?.discussion?.title ?? node.title }
        return node.title
    }
    public func search(_ query: String) -> [ReadingNode] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let titles = discussionTitles
        return nodes.filter {
            let title = $0.id.kind == .discussion ? (titles[$0.id.owner] ?? $0.title) : $0.title
            return $0.deletedAt == nil && (query.isEmpty || title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query))
        }
    }
    public func searchEdges(_ query: String) -> [ReadingEdge] {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let active = Dictionary(nodes.filter { $0.deletedAt == nil }.map { ($0.id,$0) },uniquingKeysWith:{ _,new in new })
        let titles = discussionTitles
        return edges.filter { edge in
            guard edge.deletedAt == nil, [.relationship,.association].contains(edge.id.kind),
                  let source = active[edge.id.source], let target = active[edge.id.target] else { return false }
            let sourceTitle = source.id.kind == .discussion ? (titles[source.id.owner] ?? source.title) : source.title
            let targetTitle = target.id.kind == .discussion ? (titles[target.id.owner] ?? target.title) : target.title
            return query.isEmpty || [edge.label,sourceTitle,source.text,targetTitle,target.text].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    public mutating func apply(_ mutation: ReadingGraphMutation, at date: Date = Date()) throws {
        var next = self
        switch mutation {
        case .upsert(let node):
            guard node.id.kind == node.content.kind, !node.id.owner.isEmpty else { throw ReadingGraphError.invalidIdentity }
            next.nodes.removeAll { $0.id == node.id }; next.nodes.append(node)
        case .connect(let edge):
            guard edge.id.source != edge.id.target, !edge.label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, edge.label.count <= 160 else { throw ReadingGraphError.invalidConnection }
            guard next.node(edge.id.source)?.deletedAt == nil, next.node(edge.id.source) != nil,
                  next.node(edge.id.target)?.deletedAt == nil, next.node(edge.id.target) != nil else { throw ReadingGraphError.missingEndpoint }
            next.edges.removeAll { $0.id == edge.id }; next.edges.append(edge)
        case .remove(let id), .restore(let id):
            guard let original = next.node(id) else { throw ReadingGraphError.missingEndpoint }
            let removing: Bool
            if case .remove = mutation { removing = true } else { removing = false }
            if removing == (original.deletedAt != nil) { return }
            var owned: Set<ReadingNodeID> = [id], pending = [id]
            let ownership = Dictionary(grouping:next.edges.filter { [.quotes,.discusses,.contains,.cites].contains($0.id.kind) },by:{ $0.id.source })
            while let parent = pending.popLast() {
                for edge in ownership[parent] ?? [] where owned.insert(edge.id.target).inserted { pending.append(edge.id.target) }
            }
            for i in next.nodes.indices {
                let child = next.nodes[i].id
                if child == id || (owned.contains(child) && (removing ? next.nodes[i].deletedAt == nil : next.nodes[i].deletedAt == original.deletedAt)) {
                    next.nodes[i].deletedAt = removing ? date : nil
                }
            }
        case .disconnect(let id), .restoreConnection(let id):
            guard let i = next.edges.firstIndex(where:{ $0.id == id }) else { throw ReadingGraphError.missingEndpoint }
            if case .disconnect = mutation { next.edges[i].deletedAt = date } else { next.edges[i].deletedAt = nil }
        }
        try next.validate(); next.rebuild(); self = next
    }
    public mutating func replaceEntities(_ values: [BookEntity]) {
        nodes.removeAll { $0.id.kind == .entity }
        nodes += values.map { value in
            var payload = value; payload.deletedAt = nil
            return ReadingNode(id:.init(.entity,value.id.uuidString),content:.entity(payload),deletedAt:value.deletedAt)
        }
        rebuild()
    }
    public mutating func replaceAnnotations(_ values: [ReaderAnnotation]) {
        let incoming = Set(values.map(\.id)), date = Date()
        // Editing a parent must not erase independently removed messages or
        // discussions. Keep their tombstones and ownership links recoverable.
        let retained = nodes.filter { incoming.contains($0.id.owner) && $0.id.kind != .note && [.discussion,.message,.source].contains($0.id.kind) && $0.deletedAt != nil }
        let retainedIDs = Set(retained.map(\.id))
        let retainedEdges = edges.filter { $0.id.kind != .association && (retainedIDs.contains($0.id.source) || retainedIDs.contains($0.id.target)) }
        let retainedMessageOwners = Set(retained.filter { $0.id.kind == .message }.map { $0.id.owner })
        let oldMessageOrders = Dictionary(edges.filter { $0.id.kind == .contains && retainedMessageOwners.contains($0.id.source.owner) }.map { ($0.id.target,$0.order) },uniquingKeysWith:{ first,_ in first })
        let oldResponses = Dictionary(edges.filter { $0.id.kind == .responds && $0.id.source.kind == .message && retainedMessageOwners.contains($0.id.source.owner) }.map { ($0.id.source,$0.id.target) },uniquingKeysWith:{ first,_ in first })
        let previous = Set(nodes.filter { $0.id.kind == .note && $0.deletedAt == nil }.map { $0.id.owner })
        let removed = previous.subtracting(incoming)
        for i in nodes.indices where removed.contains(nodes[i].id.owner) && [.note,.discussion,.message,.source].contains(nodes[i].id.kind) && nodes[i].deletedAt == nil { nodes[i].deletedAt = date }
        nodes.removeAll { incoming.contains($0.id.owner) && [.note,.discussion,.message,.source].contains($0.id.kind) }
        edges.removeAll { incoming.contains($0.id.source.owner) && [.note,.discussion,.message,.source].contains($0.id.source.kind) && $0.id.kind != .association }
        for original in values {
            let id = ReadingNodeID(.note,original.id)
            var value = original; value.quote = ""; value.entityIDs = nil; value.responseToID = nil; value.discussion = nil
            nodes.append(.init(id:id,content:.note(.init(value:value,hadEntityList:original.entityIDs != nil))))
            if !original.quote.isEmpty {
                let source = ReadingNodeID(.source,original.id,local:"excerpt")
                nodes.append(.init(id:source,content:.source(.init(id:"原文",label:original.chapter,text:original.quote,locator:original.readingLocator,limit:Int.max))))
                edges.append(.init(kind:.quotes,source:id,target:source,label:"摘录"))
            }
            var linked = Set<UUID>()
            for (order,entity) in (original.entityIDs ?? []).enumerated() where linked.insert(entity).inserted { edges.append(.init(kind:.mentions,source:id,target:.init(.entity,entity.uuidString),label:"提及",order:order)) }
            if let parent = original.responseToID { edges.append(.init(kind:.responds,source:id,target:.init(.note,parent),label:"回应")) }
            if var discussion = original.discussion {
                let thread = ReadingNodeID(.discussion,original.id), messages = discussion.messages
                discussion.messages = []
                nodes.append(.init(id:thread,content:.discussion(discussion)))
                edges.append(.init(kind:.discusses,source:id,target:thread,label:"讨论"))
                var previous: ReadingNodeID?
                var nextOrder = (oldMessageOrders.filter { $0.key.owner == original.id }.values.max() ?? -1)+1
                for (order,message) in messages.enumerated() {
                    let messageID = ReadingNodeID(.message,original.id,local:message.id.uuidString)
                    var value = message; value.context = nil
                    nodes.append(.init(id:messageID,content:.message(.init(value:value,omittedTurns:message.context?.omittedTurns))))
                    let savedOrder: Int
                    if retainedMessageOwners.contains(original.id) { savedOrder = oldMessageOrders[messageID] ?? nextOrder; if oldMessageOrders[messageID] == nil { nextOrder += 1 } }
                    else { savedOrder = order }
                    edges.append(.init(kind:.contains,source:thread,target:messageID,label:"消息",order:savedOrder))
                    if let previous = oldResponses[messageID] ?? previous { edges.append(.init(kind:.responds,source:messageID,target:previous,label:"回应")) }
                    previous = messageID
                    for (index,source) in (message.context?.sources ?? []).enumerated() {
                        let sourceID = ReadingNodeID(.source,original.id,local:"\(message.id.uuidString)/\(index)")
                        nodes.append(.init(id:sourceID,content:.source(source)))
                        edges.append(.init(kind:.cites,source:messageID,target:sourceID,label:"引用",order:index))
                    }
                }
            }
        }
        let rebuiltIDs = Set(nodes.map(\.id)), rebuiltEdges = Set(edges.map(\.id))
        nodes += retained.filter { !rebuiltIDs.contains($0.id) }
        edges += retainedEdges.filter { !rebuiltEdges.contains($0.id) }
        rebuild()
    }
    public mutating func replacePageNotes(_ values: [ReaderPageNote]) {
        let incoming = Set(values.map { $0.id.uuidString }), date = Date()
        for i in nodes.indices where nodes[i].id.kind == .ink && !incoming.contains(nodes[i].id.owner) && nodes[i].deletedAt == nil { nodes[i].deletedAt = date }
        nodes.removeAll { $0.id.kind == .ink && incoming.contains($0.id.owner) }
        edges.removeAll { $0.id.source.kind == .ink && incoming.contains($0.id.source.owner) && $0.id.kind == .mentions }
        for original in values {
            var value = original; value.entityIDs = original.entityIDs == nil ? nil : []
            let id = ReadingNodeID(.ink,value.id.uuidString)
            nodes.append(.init(id:id,content:.ink(value)))
            var linked = Set<UUID>()
            for (order,entity) in (original.entityIDs ?? []).enumerated() where linked.insert(entity).inserted { edges.append(.init(kind:.mentions,source:id,target:.init(.entity,entity.uuidString),label:"提及",order:order)) }
        }
        rebuild()
    }
    public mutating func replaceRelations(_ values: [BookRelation]) {
        edges.removeAll { $0.id.kind == .relationship && $0.id.source.kind == .entity && $0.id.target.kind == .entity }
        edges += values.map { value in
            var edge = ReadingEdge(kind:.relationship,source:.init(.entity,value.sourceID.uuidString),target:.init(.entity,value.targetID.uuidString),label:value.label,record:value.id)
            edge.relationship = .init(id:value.id,conjecture:value.conjecture,standalone:value.standalone,chapterHref:value.chapterHref,progress:value.progress,evidence:value.evidenceIDs)
            edge.deletedAt = value.deletedAt; return edge
        }
        rebuild()
    }
    private mutating func rebuild() {
        let byID = Dictionary(nodes.map { ($0.id,$0) },uniquingKeysWith:{ _,new in new })
        let outgoing = Dictionary(grouping:edges.filter { $0.deletedAt == nil },by:{ $0.id.source })
        func links(_ id: ReadingNodeID,_ kind: ReadingEdge.Kind) -> [ReadingEdge] { (outgoing[id] ?? []).filter { $0.id.kind == kind }.sorted { $0.order < $1.order } }
        func message(_ node: ReadingNode) -> ReaderDiscussionMessage? {
            guard node.deletedAt == nil, case .message(let stored) = node.content else { return nil }
            var value = stored.value
            if let omitted = stored.omittedTurns {
                let sources = links(node.id,.cites).compactMap { edge -> ReaderDiscussionSource? in
                    guard let source = byID[edge.id.target], source.deletedAt == nil, case .source(let value) = source.content else { return nil }; return value
                }
                value.context = .init(sources:sources,omittedTurns:omitted)
            }
            return value
        }
        noteCache = []; entityCache = []; inkCache = []; relationCache = []
        for node in nodes {
            switch node.content {
            case .entity(var value): value.deletedAt = node.deletedAt; entityCache.append(value)
            case .note(let stored) where node.deletedAt == nil:
                var value = stored.value
                value.title = value.discussionLabel(value.title)
                if let sourceID = links(node.id,.quotes).first?.id.target, let source = byID[sourceID], source.deletedAt == nil, case .source(let text) = source.content { value.quote = text.text }
                let entities = links(node.id,.mentions).compactMap { UUID(uuidString:$0.id.target.owner) }
                if stored.hadEntityList || !entities.isEmpty { value.entityIDs = entities }
                value.responseToID = links(node.id,.responds).first?.id.target.owner
                if let threadID = links(node.id,.discusses).first?.id.target, let thread = byID[threadID], thread.deletedAt == nil, case .discussion(var discussion) = thread.content {
                    discussion.messages = links(threadID,.contains).compactMap { byID[$0.id.target].flatMap(message) }; value.discussion = discussion
                }
                noteCache.append(value)
            case .ink(var value) where node.deletedAt == nil:
                let ids = links(node.id,.mentions).compactMap { UUID(uuidString:$0.id.target.owner) }
                if !ids.isEmpty { value.entityIDs = ids }; inkCache.append(value)
            default: break
            }
        }
        for edge in edges where edge.id.kind == .relationship {
            guard let data = edge.relationship, let source = UUID(uuidString:edge.id.source.owner), let target = UUID(uuidString:edge.id.target.owner) else { continue }
            var value = BookRelation(id:data.id,sourceID:source,targetID:target,label:edge.label,evidenceIDs:data.evidence,conjecture:data.conjecture)
            value.standalone = data.standalone; value.chapterHref = data.chapterHref; value.progress = data.progress; value.deletedAt = edge.deletedAt
            relationCache.append(value)
        }
    }
}
