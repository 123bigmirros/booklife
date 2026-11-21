import Foundation
import CryptoKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

struct MindMapTopic: Codable, Equatable {
    struct Metadata: Codable, Equatable {
        var kind: String
        var nodeID: ReadingNodeID?
        var chapterID: Int?
        var inkParts: [MindMapInkPart]?
        var inkEntityIDs: [UUID]?
        var attachedNodes: [ReadingNodeID]?
        var chapterTitle: String?
        var name: String?
        var summary: String?
    }
    var id: String
    var topic: String
    var children: [MindMapTopic] = []
    var expanded: Bool = true
    var direction: Int?
    var tags: [String]?
    var note: String?
    var metadata: Metadata?
    var dangerouslySetInnerHTML: String?
    private enum CodingKeys: String,CodingKey { case id,topic,children,expanded,direction,tags,note,metadata,dangerouslySetInnerHTML }
    init(id: String,topic: String,metadata: Metadata? = nil) { self.id = id; self.topic = topic; self.metadata = metadata }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(String.self,forKey:.id); topic = try c.decode(String.self,forKey:.topic)
        children = try c.decodeIfPresent([MindMapTopic].self,forKey:.children) ?? []
        expanded = try c.decodeIfPresent(Bool.self,forKey:.expanded) ?? true
        direction = try c.decodeIfPresent(Int.self,forKey:.direction)
        tags = try c.decodeIfPresent([String].self,forKey:.tags); note = try c.decodeIfPresent(String.self,forKey:.note)
        metadata = try c.decodeIfPresent(Metadata.self,forKey:.metadata)
        dangerouslySetInnerHTML = try c.decodeIfPresent(String.self,forKey:.dangerouslySetInnerHTML)
    }
}
struct MindMapInkPart: Codable, Equatable {
    var id: UUID
    var title: String?
    var quote: String
    var image: String
    var aspect: Double
    var text: String?
    var entityIDs: [UUID]?
    init(_ part: ReaderInkPart) {
        id=part.id;quote=String(part.quote.prefix(1200))
        title=part.title
        let b=part.bounds,a=part.anchor
        image="bookslide-ink://\(part.assetID.uuidString)/preview.png?x=\(b.x/a.viewportWidth)&y=\(b.y/a.viewportHeight)&w=\(b.width/a.viewportWidth)&h=\(b.height/a.viewportHeight)"
        aspect=max(0.1,min(8,b.height/max(1,b.width)))
        text=part.text;entityIDs=part.entityIDs
    }
}
struct MindMapArrow: Codable, Equatable {
    var id: String
    var label: String
    var from: String
    var to: String
    var edgeID: ReadingEdge.ID?
}
struct MindMapDocument: Codable, Equatable {
    var nodeData: MindMapTopic
    var arrows: [MindMapArrow] = []
    var direction = 1
    // Older recovery files carry a separate title in each topic.
    var contentTopics: Bool? = true
    var editedTopics: [String]?
    func topic(containing id: ReadingNodeID) -> MindMapTopic? {
        (try? flattened())?.first { $0.topic.metadata?.nodeID == id || $0.topic.metadata?.attachedNodes?.contains(id) == true }?.topic
    }
    func flattened() throws -> [(topic:MindMapTopic,parent:String?)] {
        var result: [(MindMapTopic,String?)] = [], seen = Set<String>()
        func visit(_ node: MindMapTopic,parent: String?,depth: Int) throws {
            guard depth < 128, result.count < 10000, !node.id.isEmpty, node.id.count <= 512,
                  seen.insert(node.id).inserted, node.topic.count <= 100000 else { throw ReadingGraphError.invalidIdentity }
            result.append((node,parent))
            for child in node.children { try visit(child,parent:node.id,depth:depth+1) }
        }
        try visit(nodeData,parent:nil,depth:0); return result
    }
}
struct MindMapCommand: Equatable { let id = UUID(); var name: String; var target: String? = nil }

extension ReaderAnnotation {
    var canvasText: String {
        if !note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return note }
        if discussionScope != nil || (discussion != nil && title == ReaderDiscussion.defaultTitle) { return "" }
        return title ?? ""
    }
    var canvasDisplayText: String {
        let content = canvasText.trimmingCharacters(in:.whitespacesAndNewlines)
        if !content.isEmpty { return content }
        let excerpt = quote.trimmingCharacters(in:.whitespacesAndNewlines)
        if !excerpt.isEmpty { return excerpt }
        if let question = discussion?.title, question != ReaderDiscussion.defaultTitle { return question }
        return "新节点"
    }
}

extension ReaderPageNote {
    var canvasText: String {
        let body = text ?? ""
        return body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? title ?? "" : body
    }
}

extension ReadingNode {
    var canvasSearchText: String {
        switch content {
        case .note(let note): return note.value.canvasDisplayText
        case .ink(let note): return note.excerpt.isEmpty ? "手写标记" : note.excerpt
        default: return title
        }
    }
}

extension ReaderModel {
    private func canvasHash(_ value: String) -> String { SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
    private func canvasUUID(_ value: String) -> UUID {
        let b = Array(SHA256.hash(data:Data(value.utf8)).prefix(16))
        return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    func mindMapToken(_ id: ReadingNodeID) -> String {
        if let saved = currentBook?.graph.canvasNodes.first(where:{ $0.nodeID == id }) { return saved.id }
        return id.kind == .note ? id.owner : id.kind.rawValue+":"+id.owner
    }
    func mindMapDocument(includeFuture: Bool = false) -> MindMapDocument {
        let index = bookNotesIndex, root = "book:"+(currentID?.uuidString ?? "none")
        let saved = Dictionary(currentBook?.graph.canvasNodes.map { ($0.id,$0) } ?? [],uniquingKeysWith:{ _,last in last })
        func topic(_ id: String,_ title: String,kind: String,nodeID: ReadingNodeID? = nil,chapter: Int? = nil) -> MindMapTopic {
            var value = MindMapTopic(id:id,topic:title,metadata:.init(kind:kind,nodeID:nodeID,chapterID:chapter))
            value.expanded = saved[id]?.expanded ?? true; value.direction = saved[id]?.direction ?? 1
            if kind == "chapter" || kind == "book" {
                let escaped = title.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
                value.dangerouslySetInnerHTML = "<span class=\"text\">"+escaped+"</span>"
            }
            return value
        }
        var topics: [String:MindMapTopic] = [root:topic(root,currentBook?.title ?? "阅读结构图",kind:"book")]
        var parent: [String:String] = [:], order: [String:Int] = [root:0], chapterTokens: [Int:String] = [:]
        for node in index.structure.nodes {
            let token = "chapter:"+canvasHash(node.entry.href+"|"+node.entry.title).prefix(24)
            chapterTokens[node.id] = token
            topics[token] = topic(token,node.entry.title,kind:"chapter",chapter:node.id)
            order[token] = order.count
        }
        for node in index.structure.nodes {
            if let token = chapterTokens[node.id] { parent[token] = node.parent.flatMap { chapterTokens[$0] } ?? root }
        }
        let notes = Dictionary(index.notes.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
        let annotations = Dictionary(graphAnnotations.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
        let chapterByScope = Dictionary(chapters.enumerated().map { ($0.element.discussionScope,$0.offset) },uniquingKeysWith:{ first,_ in first })
        var visible = index.searchNodes("",through:noteVisibilityProgress,includeFuture:includeFuture).filter { [.note,.entity,.ink,.discussion].contains($0.id.kind) }
        // A selection can extend below the viewport's progress anchor. Its
        // active draft still needs a visible, editable node in the map.
        if let draft = annotationDraft, draft.bookID == currentID,
           let node = index.graph.node(.init(.note,draft.id)), !visible.contains(where:{ $0.id == node.id }) { visible.append(node) }
        let visibleIDs = Set(visible.map(\.id))
        var attachment: [ReadingNodeID:String] = [:]
        var ownersWithThread = Set<ReadingNodeID>()
        // The graph stores conversations separately for search and export. Present the
        // conversation on its owner, including threads created by earlier versions.
        for edge in index.graph.edges where edge.deletedAt == nil && edge.label == "AI 对话"
            && edge.id.kind == .association && [.entity,.ink].contains(edge.id.source.kind)
            && edge.id.target.kind == .discussion && visibleIDs.contains(edge.id.source)
            && visibleIDs.contains(edge.id.target) && attachment[edge.id.target] == nil {
            if ownersWithThread.insert(edge.id.source).inserted {
                let owner = mindMapToken(edge.id.source)
                attachment[edge.id.target] = owner
                attachment[.init(.note,edge.id.target.owner)] = owner
            }
        }
        for node in visible where (node.id.kind == .discussion || annotations[node.id.owner]?.discussionScope != nil) && attachment[node.id] == nil {
            let noteID = ReadingNodeID(.note,node.id.owner)
            if let scope = annotations[node.id.owner]?.discussionScope,
               let owner = scope == ReaderDiscussion.bookScope ? root : chapterByScope[scope].flatMap({ chapterTokens[$0] }) {
                attachment[noteID] = owner
                attachment[node.id] = owner
            } else if node.id.kind == .discussion && visibleIDs.contains(noteID) {
                attachment[node.id] = mindMapToken(noteID)
            }
        }
        func tokenFor(_ id: ReadingNodeID) -> String { attachment[id] ?? mindMapToken(id) }
        for node in visible where attachment[node.id] == nil {
            let annotation = annotations[node.id.owner]
            let scopedNote = annotation?.discussionScope == nil ? nil : annotation
            let scope = scopedNote?.discussionScope
            let token = mindMapToken(node.id)
            var title = index.graph.title(for:node.id) ?? node.title
            let source = notes[node.id.owner]
            if node.id.kind == .note { title = annotation?.canvasDisplayText ?? node.canvasSearchText }
            if node.id.kind == .discussion {
                let label = saved[token]?.label
                title = (scopedNote == nil ? label : scopedNote?.discussionLabel(label) ?? scopedNote?.title) ?? title
            }
            var value = topic(token,String(title.prefix(node.id.kind == .note ? 100000 : 160)),kind:node.id.kind.rawValue,nodeID:node.id)
            value.metadata?.chapterTitle = source?.chapter
            if case .note = node.content { value.metadata?.name = annotation?.attributes?.name }
            if case .entity(let entity) = node.content { value.metadata?.summary = entity.note.map { String($0.prefix(300)) } }
            if case .ink(let stored)=node.content {
                let ink=currentPageNotes.first(where:{ $0.id==stored.id }) ?? stored
                value.topic=String(ink.canvasText.trimmingCharacters(in:.whitespacesAndNewlines).prefix(100000))
                value.metadata?.name = ink.attributes?.name
                value.metadata?.inkParts=ink.inkParts.map(MindMapInkPart.init)
                value.metadata?.inkEntityIDs=ink.entityIDs
                value.note=ink.text
            }
            topics[token] = value; order[token] = order.count
            parent[token] = source?.chapterID.flatMap { chapterTokens[$0] } ?? root
            if let scope, node.id.kind == .discussion {
                parent[token] = chapterByScope[scope].flatMap { chapterTokens[$0] } ?? root
            }
            if node.id.kind == .entity, case .entity(let entity) = node.content {
                parent[token] = index.structure.sectionID(href:entity.chapterHref,title:"").flatMap { chapterTokens[$0] } ?? root
            }
        }
        var formerTokens: [String:String] = [:]
        for (id,owner) in attachment {
            formerTokens[mindMapToken(id)] = owner
            if topics[owner]?.metadata?.attachedNodes == nil { topics[owner]?.metadata?.attachedNodes = [] }
            topics[owner]?.metadata?.attachedNodes?.append(id)
        }
        for token in Set(attachment.values) {
            topics[token]?.metadata?.attachedNodes?.sort { ($0.owner,$0.kind.rawValue) < ($1.owner,$1.kind.rawValue) }
        }
        for edge in index.associations where ["子主题","AI 对话"].contains(edge.label) {
            let a = tokenFor(edge.id.source), b = tokenFor(edge.id.target)
            if a != b && topics[a] != nil && topics[b] != nil { parent[b] = a }
        }
        for (token,state) in saved where token != root && topics[token] != nil {
            if let previous = state.parent {
                let p = formerTokens[previous] ?? previous
                if topics[p] != nil && p != token { parent[token] = p }
            }
            order[token] = state.order
        }
        // Imports can contain semantic cycles; choose a safe tree without losing any node.
        for token in topics.keys where token != root {
            var seen: Set<String> = [token], ancestor = parent[token]
            while let current = ancestor, current != root {
                if !seen.insert(current).inserted { parent[token] = root; break }
                ancestor = parent[current]
            }
        }
        let children = Dictionary(grouping:parent.keys,by:{ parent[$0] ?? root })
        func build(_ token: String) -> MindMapTopic {
            var value = topics[token]!
            value.children = (children[token] ?? []).sorted { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) }.map(build)
            return value
        }
        var document = MindMapDocument(nodeData:build(root))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for edge in index.graph.searchEdges("") where [.association,.relationship,.mentions].contains(edge.id.kind) {
            let a = tokenFor(edge.id.source), b = tokenFor(edge.id.target)
            guard a != b, topics[a] != nil, topics[b] != nil else { continue }
            if ["子主题","AI 对话"].contains(edge.label), parent[b] == a { continue }
            let id = "edge:"+canvasHash((try? String(data:encoder.encode(edge.id),encoding:.utf8)) ?? "").prefix(24)
            document.arrows.append(.init(id:id,label:edge.label,from:a,to:b,edgeID:edge.id))
        }
        return document
    }
    /// Commit a library operation as one graph write. The engine never becomes a second database.
    func applyMindMapDocument(_ document: MindMapDocument,baseline: MindMapDocument,bookID: UUID) -> Bool {
        guard bookID == currentID else { error = "图书已切换，当前导图修改未保存。"; return false }
        do {
            let before = try baseline.flattened(), after = try document.flattened()
            let old = Dictionary(before.map { ($0.topic.id,$0) },uniquingKeysWith:{ first,_ in first })
            let incoming = Dictionary(after.map { ($0.topic.id,$0) },uniquingKeysWith:{ first,_ in first })
            let textEdits = document.editedTopics.map(Set.init)
            guard document.nodeData.id == baseline.nodeData.id, document.arrows.count <= 10000 else { throw ReadingGraphError.invalidIdentity }
            for row in before where row.topic.metadata?.nodeID == nil {
                guard let current = incoming[row.topic.id], current.topic.topic == row.topic.topic else { throw ReadingGraphError.invalidIdentity }
                // Chapters may be arranged inside the canvas without editing
                // the EPUB's table of contents or nesting them inside notes.
                if let parent = current.parent {
                    guard incoming[parent]?.topic.metadata?.nodeID == nil else { throw ReadingGraphError.invalidIdentity }
                } else if row.topic.id != baseline.nodeData.id { throw ReadingGraphError.invalidIdentity }
            }
            var resolved: [String:ReadingNodeID] = [:]
            var inkRegistry: [UUID:ReaderInkPart]=[:]
            let inkRecords=(currentBook?.graph.nodes.compactMap { node -> ReaderPageNote? in
                guard case .ink(var note)=node.content else { return nil }
                note.entityIDs=currentBook?.graph.edges.filter { $0.deletedAt==nil && $0.id.source==node.id && $0.id.kind == .mentions }.compactMap { UUID(uuidString:$0.id.target.owner) }
                return note
            } ?? []).sorted { $0.updatedAt<$1.updatedAt }
            for note in inkRecords { for part in note.inkParts { inkRegistry[part.id]=part } }
            for row in after {
                if let id = old[row.topic.id]?.topic.metadata?.nodeID { resolved[row.topic.id] = id }
                else if old[row.topic.id] == nil {
                    let pieces = row.topic.id.split(separator:":",maxSplits:1).map(String.init)
                    if pieces.count == 2, let kind = ReadingNodeID.Kind(rawValue:pieces[0]), [.entity,.discussion,.ink].contains(kind), UUID(uuidString:pieces[1]) != nil,
                       (currentBook?.graph.node(.init(kind,pieces[1])) != nil || (kind == .ink && UUID(uuidString:pieces[1]).flatMap { inkRegistry[$0] } != nil)) {
                        resolved[row.topic.id] = .init(kind,pieces[1])
                    } else {
                        guard !row.topic.id.contains(":"), row.topic.id.count <= 128 else { throw ReadingGraphError.invalidIdentity }
                        resolved[row.topic.id] = .init(.note,(UUID(uuidString:row.topic.id) ?? canvasUUID(bookID.uuidString+"/"+row.topic.id)).uuidString)
                    }
                }
            }
            let requestedParts=after.filter { resolved[$0.topic.id]?.kind == .ink }.flatMap { row in
                row.topic.metadata?.inkParts?.map(\.id) ?? inkRecords.first(where:{ $0.id.uuidString==resolved[row.topic.id]?.owner })?.inkParts.map(\.id) ?? []
            }
            guard Set(requestedParts).count==requestedParts.count else { throw ReadingGraphError.invalidIdentity }
            let drafts = graphAnnotations
            let recovery = MindMapRecovery(bookID:bookID,document:document,baseline:baseline)
            try? saveMindMapRecovery(recovery)
            let saved = commitReadingGraph(bookID:bookID) { graph in
                func recordID(_ id: ReadingNodeID) -> ReadingNodeID {
                    let noteID = ReadingNodeID(.note,id.owner)
                    if id.kind == .discussion, case .note(let note) = graph.node(noteID)?.content, note.value.discussionScope != nil {
                        return noteID
                    }
                    return id
                }
                func ownedNotes(_ id: ReadingNodeID) -> [ReadingNodeID] {
                    guard [.entity,.ink].contains(id.kind),
                          let edge = graph.edges.first(where:{ $0.id.source == id && $0.id.target.kind == .discussion
                            && $0.id.kind == .association && $0.label == "AI 对话" && $0.deletedAt == nil }) else { return [] }
                    return [.init(.note,edge.id.target.owner)]
                }
                for id in resolved.values where graph.node(id)?.deletedAt != nil {
                    let removalDate = graph.node(id)?.deletedAt
                    for child in ownedNotes(id) where graph.node(child)?.deletedAt == removalDate { try graph.apply(.restore(child)) }
                    try graph.apply(.restore(recordID(id)))
                    graph.removals.removeAll { $0.annotation?.id == id.owner || $0.pageNote?.id.uuidString == id.owner }
                }
                var annotations = graph.annotations, entities = graph.entities, ink = graph.pageNotes
                for row in after {
                    guard let id = resolved[row.topic.id] else { continue }
                    let title = row.topic.topic.trimmingCharacters(in:.whitespacesAndNewlines)
                    let previous = old[row.topic.id]?.topic
                    let usesContent = baseline.contentTopics == true && (id.kind == .note || id.kind == .ink)
                    let limit = usesContent ? 100000 : id.kind == .entity ? 80 : 160
                    guard title.count <= limit, usesContent || !title.isEmpty else { throw ReadingGraphError.invalidIdentity }
                    let edited = textEdits?.contains(row.topic.id) ?? (previous?.topic != row.topic.topic)
                    switch id.kind {
                    case .note:
                        let existing = annotations.firstIndex(where:{ $0.id == id.owner })
                        var note = existing.map { annotations[$0] } ?? drafts.first(where:{ $0.id == id.owner }) ?? ReaderAnnotation(id:id.owner,cfi:"",quote:"",chapter:position?.chapter ?? "阅读笔记",progress:position?.progress ?? 0)
                        if edited, existing == nil || previous != nil {
                            if usesContent { note.note = title == "新节点" && note.quote.isEmpty ? "" : title }
                            else { note.title = title }
                            note.updatedAt = Date()
                        }
                        if let existing { annotations[existing] = note }
                        else {
                            note.chapterHref = note.chapterHref ?? position?.chapterHref
                            if old[row.topic.id] == nil {
                                if !usesContent { note.note = String((row.topic.note ?? "").prefix(100000)) }
                                var ancestor = row.parent
                                while let token = ancestor {
                                    if let owner = resolved[token], let source = annotations.first(where:{ $0.id == owner.owner }) {
                                        note.chapter = source.chapter; note.chapterHref = source.chapterHref; note.progress = source.progress; break
                                    }
                                    if let section = old[token]?.topic.metadata?.chapterID, chapters.indices.contains(section) {
                                        note.chapter = chapters[section].title; note.chapterHref = chapters[section].href; break
                                    }
                                    ancestor = incoming[token]?.parent
                                }
                            }
                            annotations.append(note)
                        }
                    case .entity:
                        guard let i = entities.firstIndex(where:{ $0.id.uuidString == id.owner }) else { throw ReadingGraphError.missingEndpoint }
                        guard edited, previous != nil else { continue }
                        if entities[i].name != title, entities.contains(where:{ $0.id != entities[i].id && $0.deletedAt == nil && $0.kind == entities[i].kind && ([$0.name]+$0.aliases).contains { $0.caseInsensitiveCompare(title) == .orderedSame } }) { throw ReadingGraphError.invalidIdentity }
                        entities[i].name = title
                        entities[i].aliases.removeAll { $0.caseInsensitiveCompare(title) == .orderedSame }
                    case .ink:
                        let existing=ink.firstIndex(where:{ $0.id.uuidString==id.owner })
                        let partIDs=row.topic.metadata?.inkParts?.map(\.id)
                        let parts=try partIDs?.map { key -> ReaderInkPart in
                            guard let part=inkRegistry[key] else { throw ReadingGraphError.missingEndpoint };return part
                        }
                        var value: ReaderPageNote
                        if let existing { value=ink[existing] }
                        else if let first=parts?.first, let uuid=UUID(uuidString:id.owner) {
                            value=ReaderPageNote(id:uuid,assetID:first.assetID,anchor:first.anchor)
                        } else { throw ReadingGraphError.missingEndpoint }
                        let originalParts=value.inkParts
                        let originalText=value.text ?? ""
                        let originalEntities=value.entityIDs ?? []
                        let changedParts=partIDs.map { originalParts.map(\.id) != $0 } ?? false
                        if let parts, changedParts || existing == nil {
                            guard !parts.isEmpty, parts.count<=1000 else { throw ReadingGraphError.invalidIdentity }
                            value.parts=parts;value.anchor=parts[0].anchor;value.assetID=parts[0].assetID
                        }
                        if changedParts || existing==nil {
                            value.manualGrouping=true
                            let combined=originalParts.compactMap(\.text).filter { !$0.isEmpty }.joined(separator:"\n\n")
                            let keepsPrimary=parts?.contains(where:{ $0.id==originalParts.first?.id }) == true
                            let editedGroup=originalParts.count>1 && originalText != combined
                            value.text=editedGroup && keepsPrimary ? originalText : (parts ?? []).compactMap(\.text).filter { !$0.isEmpty }.joined(separator:"\n\n")
                            let oldEntities=Set(originalParts.flatMap { $0.entityIDs ?? [] })
                            let extras=keepsPrimary ? originalEntities.filter { !oldEntities.contains($0) } : []
                            value.entityIDs=Array(Set((parts ?? []).flatMap { $0.entityIDs ?? [] }+extras))
                        }
                        if edited && !changedParts && previous != nil {
                            if usesContent { value.text=title }
                            else { value.title=title }
                            value.updatedAt=Date()
                        } else if changedParts {
                            if !usesContent { value.title=title }
                            value.updatedAt=Date()
                        }
                        if let existing { ink[existing]=value } else { ink.append(value) }
                    default: break
                    }
                }
                graph.replaceEntities(entities); graph.replaceAnnotations(annotations); graph.replacePageNotes(ink)
                let absent = before.compactMap { incoming[$0.topic.id] == nil ? $0.topic.metadata?.nodeID : nil }
                for nodeID in absent {
                    let id = recordID(nodeID)
                    guard graph.node(id)?.deletedAt == nil, graph.node(id) != nil else { continue }
                    if id.kind == .note, let note = graph.annotations.first(where:{ $0.id == id.owner }) { graph.removals.append(.init(annotation:note)) }
                    let ink = graph.pageNotes.first { id.kind == .ink && $0.id.uuidString == id.owner }
                    let absorbed = ink?.inkParts.allSatisfy { requestedParts.contains($0.id) } == true
                    if let ink, !absorbed { graph.removals.append(.init(pageNote:ink)) }
                    let removalDate = Date()
                    for child in ownedNotes(id) where !absorbed && graph.node(child).map({ $0.deletedAt == nil }) == true {
                        try graph.apply(.remove(child),at:removalDate)
                    }
                    try graph.apply(.remove(id),at:removalDate)
                }
                for row in after {
                    guard let target = resolved[row.topic.id], let p = row.parent, let source = resolved[p], source != target,
                          old[row.topic.id]?.parent != p else { continue }
                    for edge in graph.searchEdges("") where edge.id.target == target && edge.id.kind == .association && ["子主题","AI 对话"].contains(edge.label) {
                        try graph.apply(.disconnect(edge.id))
                    }
                    let label = target.kind == .discussion ? "AI 对话" : "子主题"
                    let edge = ReadingEdge(kind:.association,source:source,target:target,label:label,record:canvasUUID(bookID.uuidString+"/branch/"+row.topic.id))
                    try graph.apply(.connect(edge))
                }
                let oldArrows = Dictionary(baseline.arrows.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
                let liveArrows = Set(document.arrows.map(\.id))
                for arrow in baseline.arrows where !liveArrows.contains(arrow.id) { if let id = arrow.edgeID { try graph.apply(.disconnect(id)) } }
                func endpoint(_ token: String) throws -> ReadingNodeID {
                    if let id = resolved[token] { return id }
                    guard let topic = old[token]?.topic, let metadata = topic.metadata else { throw ReadingGraphError.invalidConnection }
                    let chapter = metadata.chapterID.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil }
                    guard metadata.kind == "book" || (metadata.kind == "chapter" && chapter != nil) else { throw ReadingGraphError.invalidConnection }
                    let scope = chapter?.discussionScope ?? ReaderDiscussion.bookScope
                    if let existing = graph.annotations.first(where:{ $0.discussionScope == scope }) { return .init(.note,existing.id) }
                    var anchor = ReaderAnnotation(cfi:"",quote:"",chapter:chapter?.title ?? "全书",progress:0)
                    anchor.title = topic.topic
                    anchor.discussionScope = scope
                    anchor.chapterHref = chapter?.href
                    graph.replaceAnnotations(graph.annotations + [anchor])
                    return .init(.note,anchor.id)
                }
                for arrow in document.arrows {
                    let prior = oldArrows[arrow.id]
                    // Undo may bring back a projected connection absent from the
                    // baseline. Keep its original thread endpoint on restoration.
                    let restoring = prior == nil && arrow.edgeID.map { id in graph.edges.contains { $0.id == id && $0.deletedAt != nil } } == true
                    let sourceID = restoring ? arrow.edgeID?.source : (prior?.from == arrow.from ? prior?.edgeID?.source : nil)
                    let targetID = restoring ? arrow.edgeID?.target : (prior?.to == arrow.to ? prior?.edgeID?.target : nil)
                    let source = try sourceID ?? endpoint(arrow.from)
                    let target = try targetID ?? endpoint(arrow.to)
                    guard source != target else { throw ReadingGraphError.invalidConnection }
                    let label = arrow.label.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !label.isEmpty, label.count <= 160 else { throw ReadingGraphError.invalidConnection }
                    if let id = oldArrows[arrow.id]?.edgeID ?? arrow.edgeID, let stored = graph.edges.first(where:{ $0.id == id }) {
                        var edge = stored; edge.label = label; edge.deletedAt = nil
                        if edge.id.source != source || edge.id.target != target {
                            try graph.apply(.disconnect(edge.id));edge.id.source=source;edge.id.target=target
                        }
                        try graph.apply(.connect(edge))
                    } else {
                        let edge = ReadingEdge(kind:.association,source:source,target:target,label:label,record:canvasUUID(bookID.uuidString+"/arrow/"+arrow.id))
                        try graph.apply(.connect(edge))
                    }
                }
                let touched = Set(old.keys).union(incoming.keys)
                graph.canvasNodes.removeAll { touched.contains($0.id) }
                graph.canvasNodes += after.enumerated().map { order,row in
                    .init(id:row.topic.id,nodeID:resolved[row.topic.id],parent:row.parent,order:order,expanded:row.topic.expanded,direction:row.topic.direction,label:resolved[row.topic.id]?.kind == .discussion ? row.topic.topic : nil)
                }
            }
            if saved { try? FileManager.default.removeItem(at:mindMapRecoveryURL(bookID)) }
            else if loadMindMapRecovery(bookID) != nil { error = "导图暂未写入书库，已保留本机草稿。" }
            return saved
        } catch { self.error = "导图修改未能保存：\(error.localizedDescription)"; return false }
    }
}

struct MindMapRecovery: Codable { var bookID: UUID; var document: MindMapDocument; var baseline: MindMapDocument }
extension ReaderModel {
    private func mindMapRecoveryURL(_ id: UUID) -> URL { directory.appendingPathComponent("CanvasDrafts",isDirectory:true).appendingPathComponent(id.uuidString+".json") }
    private func saveMindMapRecovery(_ value: MindMapRecovery) throws {
        let url = mindMapRecoveryURL(value.bookID)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
    }
    func loadMindMapRecovery(_ id: UUID) -> MindMapRecovery? {
        guard let data = try? Data(contentsOf:mindMapRecoveryURL(id)), data.count <= 16*1024*1024,
              let value = try? JSONDecoder().decode(MindMapRecovery.self,from:data), value.bookID == id else { return nil }
        return value
    }
}
