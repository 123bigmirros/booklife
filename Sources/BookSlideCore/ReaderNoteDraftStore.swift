import Foundation

/// Removed notes stay in the book index until explicitly restored. Their ink
/// assets remain referenced, including when the library falls back to a backup.
public struct ReaderRemovedNote: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var removedAt = Date()
    public var annotation: ReaderAnnotation?
    public var pageNote: ReaderPageNote?
    public var noteOnly: Bool
    public init(annotation: ReaderAnnotation? = nil, pageNote: ReaderPageNote? = nil, noteOnly: Bool = false) {
        self.annotation = annotation; self.pageNote = pageNote; self.noteOnly = noteOnly
    }
}

public struct ReaderTextNoteDraft: Codable, Identifiable {
    public var bookID: UUID
    public var annotation: ReaderAnnotation
    public var updatedAt = Date()
    public var id: String { annotation.id }
    public init(bookID: UUID, annotation: ReaderAnnotation) { self.bookID = bookID; self.annotation = annotation }
}

public struct ReaderInkNoteDraft: Codable, Identifiable {
    public var bookID: UUID
    public var note: ReaderPageNote
    public var page: Data
    public var drawing: Data
    public var updatedAt = Date()
    public var id: UUID { note.id }
    public init(bookID: UUID, note: ReaderPageNote, page: Data, drawing: Data) {
        self.bookID = bookID; self.note = note; self.page = page; self.drawing = drawing
    }
}

/// Each draft is one atomic file, independent of library/progress writes.
/// Replacing it also bounds disk use during a long handwriting session.
public struct ReaderNoteDraftStore {
    public let directory: URL
    public init(libraryDirectory: URL) { directory = libraryDirectory.appendingPathComponent("NoteDrafts",isDirectory:true) }
    private func folder(_ bookID: UUID) -> URL { directory.appendingPathComponent(bookID.uuidString,isDirectory:true) }
    private func file(_ bookID: UUID, _ id: UUID, ink: Bool) -> URL {
        folder(bookID).appendingPathComponent("\(ink ? "ink" : "text")-\(id.uuidString).json")
    }
    private func write<T: Encodable>(_ value: T, bookID: UUID, id: UUID, ink: Bool) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at:folder(bookID),withIntermediateDirectories:true)
        try data.write(to:file(bookID,id,ink:ink),options:.atomic)
    }
    public func save(_ draft: ReaderTextNoteDraft) throws {
        guard let id = UUID(uuidString:draft.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try write(draft,bookID:draft.bookID,id:id,ink:false)
    }
    public func save(_ draft: ReaderInkNoteDraft) throws {
        guard !draft.page.isEmpty, !draft.drawing.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try write(draft,bookID:draft.bookID,id:draft.id,ink:true)
    }
    private func read<T: Decodable>(_ type: T.Type, bookID: UUID, ink: Bool) throws -> [T] {
        guard FileManager.default.fileExists(atPath:folder(bookID).path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:folder(bookID),includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent.hasPrefix(ink ? "ink-" : "text-") && $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(type,from:Data(contentsOf:$0)) }
    }
    public func textDrafts(bookID: UUID) throws -> [ReaderTextNoteDraft] {
        try read(ReaderTextNoteDraft.self,bookID:bookID,ink:false).filter { $0.bookID == bookID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func inkDrafts(bookID: UUID) throws -> [ReaderInkNoteDraft] {
        try read(ReaderInkNoteDraft.self,bookID:bookID,ink:true).filter { $0.bookID == bookID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func remove(bookID: UUID, id: UUID, ink: Bool) throws {
        let url = file(bookID,id,ink:ink)
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
}
