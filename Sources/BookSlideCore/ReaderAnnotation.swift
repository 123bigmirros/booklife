import Foundation

public enum BookEntityKind: String, Codable, CaseIterable {
    // Keep the original raw values so existing cards and links retain identity.
    case person, organization, place, object, event, concept, other
    public var title: String {
        switch self {
        case .person: return "人物"
        case .organization: return "组织"
        case .place: return "地点"
        case .object: return "物品"
        case .event: return "事件"
        case .concept: return "概念"
        case .other: return "其他事物"
        }
    }
    public var symbol: String {
        switch self {
        case .person: return "person"
        case .organization: return "person.3"
        case .place: return "mappin.and.ellipse"
        case .object: return "shippingbox"
        case .event: return "calendar"
        case .concept: return "lightbulb"
        case .other: return "square.on.square"
        }
    }
}

public struct ReadingNodeAttributes: Codable, Equatable {
    public var name: String?
    public var kind: BookEntityKind?
    public var aliases: [String]
    public init(name: String? = nil,kind: BookEntityKind? = nil, aliases: [String] = []) {
        self.name = name
        self.kind = kind
        self.aliases = aliases
    }
}

public struct BookEntity: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: BookEntityKind
    public var aliases: [String]
    public var note: String?
    public var chapterHref: String?
    public var progress: Double?
    public var deletedAt: Date?
    public init(id: UUID = UUID(), name: String, kind: BookEntityKind, aliases: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.aliases = aliases
    }
    public func matches(_ query: String) -> Bool {
        ([name] + aliases).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Explicitly saved relationships survive removal of their source excerpts.
/// Optional metadata keeps older libraries readable.
public struct BookRelation: Codable, Equatable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var targetID: UUID
    public var label: String
    public var evidenceIDs: [String]
    public var conjecture: Bool
    public var standalone: Bool?
    public var chapterHref: String?
    public var progress: Double?
    public var deletedAt: Date?
    public init(id: UUID = UUID(), sourceID: UUID, targetID: UUID, label: String, evidenceIDs: [String], conjecture: Bool = false) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.label = label
        self.evidenceIDs = evidenceIDs; self.conjecture = conjecture
    }
}

public struct BookRelationDraft: Codable, Equatable, Identifiable {
    public var id: UUID
    public var originalID: UUID?
    public var sourceID: UUID?
    public var targetID: UUID?
    public var label: String
    public var conjecture: Bool
    public var evidenceIDs: [String]
    public init(id: UUID = UUID(), originalID: UUID? = nil, sourceID: UUID? = nil, targetID: UUID? = nil, label: String = "", conjecture: Bool = false, evidenceIDs: [String] = []) {
        self.id = id; self.originalID = originalID; self.sourceID = sourceID; self.targetID = targetID
        self.label = label; self.conjecture = conjecture; self.evidenceIDs = evidenceIDs
    }
}

public enum ReaderNoteIntent: String, Codable, CaseIterable {
    case thought, question
    public var title: String { self == .question ? "疑问" : "想法" }
}

public enum AnnotationColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, underline
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .pink: return "粉色"
        case .purple: return "紫色"
        case .underline: return "下划线"
        }
    }
}

/// A note may link to a text range or to an opaque location supplied by the reader.
public struct ReaderAnnotation: Codable, Equatable, Identifiable {
    public var id: String
    public var cfi: String
    public var quote: String
    public var chapter: String
    public var progress: Double
    public var color: AnnotationColor
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String?
    public var chapterHref: String?
    public var sourceLocator: String?
    public var selectionLocator: String? {
        if !cfi.isEmpty { return cfi }
        if let sourceLocator, PDFTextLocator.decode(sourceLocator) != nil { return sourceLocator }
        return nil
    }
    public var readingLocator: String { sourceLocator ?? (cfi.isEmpty ? (chapterHref ?? "") : cfi) }
    public var entityIDs: [UUID]?
    public var graphRelationDraft: BookRelation?
    public var intent: ReaderNoteIntent?
    public var responseToID: String?
    public var questionResolved: Bool?
    public var discussion: ReaderDiscussion?
    public var attributes: ReadingNodeAttributes?
    public var discussionScope: String?

    public func discussionLabel(_ label: String?) -> String? {
        guard let scope = discussionScope, let label else { return label }
        if scope == ReaderDiscussion.bookScope, label == "AI 读懂全书" { return ReaderDiscussion.defaultTitle }
        if scope != ReaderDiscussion.bookScope, label == "AI 解读 · 章节" || label == String("AI 解读 · \(chapter)".prefix(160)) {
            return ReaderDiscussion.defaultTitle
        }
        return label
    }

    public init(id: String = UUID().uuidString, cfi: String, quote: String, chapter: String,
                progress: Double, color: AnnotationColor = .yellow, note: String = "",
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.cfi = cfi; self.quote = quote; self.chapter = chapter
        self.progress = progress; self.color = color; self.note = note
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
