import SwiftUI
import UniformTypeIdentifiers
#if canImport(BookSlideCore)
import BookSlideCore
#endif

struct LibraryNoteRecord: Identifiable {
    let book: LibraryBook
    let note: BookGraphNote
    let updatedAt: Date
    let aliases: [String]
    let inkAssetID: UUID?
    var inkParts: [ReaderInkPart] { book.pageNotes?.first(where:{ $0.id.uuidString==note.id })?.parts ?? [] }
    var inkAssetIDs: [UUID] {
        if !inkParts.isEmpty { return Array(Set(inkParts.map(\.assetID))).sorted { $0.uuidString<$1.uuidString } }
        return inkAssetID.map { [$0] } ?? []
    }
    var id: String { book.id.uuidString + "/" + note.id }
    var kind: String { note.ink ? "手写" : note.entitySourceOnly ? "原文" : note.highlightOnly ? "摘录" : "想法" }
    var symbol: String { note.ink ? "pencil.tip" : note.highlightOnly || note.entitySourceOnly ? "text.quote" : "square.and.pencil" }
    func matches(_ query: String) -> Bool {
        let fields = [book.title,book.author,note.title,note.quote,note.text,note.chapter] + aliases
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedCaseInsensitiveContains(String(term)) }
        }
    }
}

enum LibraryNoteFilter: String, CaseIterable {
    case all = "全部记录", thoughts = "有想法", questions = "待解疑问", ink = "手写"
    func includes(_ record: LibraryNoteRecord) -> Bool {
        switch self {
        case .all: return true
        case .thoughts: return !record.note.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        case .questions: return record.note.question && !record.note.resolved
        case .ink: return record.note.ink
        }
    }
}

enum LibraryNotes {
    static func records(in books: [LibraryBook]) -> [LibraryNoteRecord] {
        books.filter { $0.hidden != true }.flatMap { book -> [LibraryNoteRecord] in
            let annotations = book.annotations ?? [], ink = book.pageNotes ?? []
            let index = BookNotesIndex(entries:[],graph:book.graph)
            let annotationsByID = Dictionary(grouping:annotations,by: \.id).mapValues { $0[0] }
            let inkByID = Dictionary(grouping:ink,by:{ $0.id.uuidString }).mapValues { $0[0] }
            let entitiesByID = Dictionary(grouping:index.entities,by: \.id).mapValues { $0[0] }
            return index.notes.map { note in
                let entities = note.entityIDs.compactMap { entitiesByID[$0] }
                return LibraryNoteRecord(book:book,note:note,
                    updatedAt:annotationsByID[note.id]?.updatedAt ?? inkByID[note.id]?.updatedAt ?? .distantPast,
                    aliases:entities.flatMap { [$0.name] + $0.aliases },inkAssetID:inkByID[note.id]?.assetID)
            }
        }
    }
    static func filtered(_ records: [LibraryNoteRecord], query: String = "", filter: LibraryNoteFilter = .all, bookID: UUID? = nil, byPosition: Bool = false) -> [LibraryNoteRecord] {
        records.filter { (bookID == nil || $0.book.id == bookID) && filter.includes($0) && $0.matches(query) }.sorted {
            if byPosition {
                if $0.book.id != $1.book.id {
                    let order = $0.book.title.localizedStandardCompare($1.book.title)
                    return order == .orderedSame ? $0.book.id.uuidString < $1.book.id.uuidString : order == .orderedAscending
                }
                if $0.note.progress != $1.note.progress { return $0.note.progress < $1.note.progress }
            } else if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}

extension ReaderModel {
    @MainActor func openLibraryNote(_ record: LibraryNoteRecord, atSource: Bool = false) async {
        guard openingLibraryNote == nil, !busy, !loading, !handwritingActive else { return }
        openingLibraryNote = record.id
        defer { openingLibraryNote = nil }
        if currentID != record.book.id {
            open(record.book.id)
            let session = sessionID
            for _ in 0..<300 {
                guard !Task.isCancelled, sessionID == session else { return }
                if !loading { break }
                do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
            }
        }
        guard !Task.isCancelled, currentID == record.book.id, !loading, error == nil, position != nil else {
            if error == nil { error = "图书尚未打开，请稍后重试。笔记仍可在这里查看和导出。" }
            return
        }
        if atSource {
            showNoteGraph = false
            if !record.note.locator.isEmpty { go(record.note.locator) }
            else { readingNotice = "这条记录没有精确的原文位置，已回到图书。" }
        } else {
            graphNoteID = record.note.id
            showNoteGraph = true
        }
    }
}

/// Cross-book results live in the graph inspector, never in a second notebook.
struct BookGraphSearchPanel: View {
    @ObservedObject var reader: ReaderModel
    let query: String
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var filter = LibraryNoteFilter.all
    private var palette: BookGraphPalette { .init(dark:colorScheme == .dark) }
    private var records: [LibraryNoteRecord] {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        return LibraryNotes.filtered(LibraryNotes.records(in:reader.books),query:query,filter:filter)
    }
    private var nodeResults: [ReadingGraphSearchHit] { reader.searchReadingGraph(query) }
    private func kindTitle(_ hit: ReadingGraphSearchHit) -> String {
        switch hit.kind {
        case .note: return "笔记"; case .entity: return "人物与卡片"; case .ink: return "手写"
        case .discussion: return "AI 对话"; case .message: return "对话消息"; case .source: return "原文与引用"; case nil: return "关系"
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Label("跨书查找",systemImage:"magnifyingglass").font(.headline)
                Spacer()
                Button("回到图中",action:close).buttonStyle(.borderless)
            }
            Text("选择结果，在对应图书的脉络中继续整理。").font(.callout).foregroundStyle(.secondary)
            Picker("记录类型",selection:$filter) {
                ForEach(LibraryNoteFilter.allCases.filter { $0 != .questions },id:\.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                Text("搜索人物、笔记、对话或原文。").foregroundStyle(.secondary)
            } else if filter == .all {
                Text("找到 \(nodeResults.count) 条记录").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        ForEach(nodeResults) { hit in
                            Button { reader.openReadingSearchHit(hit); close() } label: {
                                VStack(alignment:.leading,spacing:8) {
                                    HStack {
                                        Text(hit.bookTitle).foregroundStyle(palette.accent)
                                        Spacer(minLength:8)
                                        Text(kindTitle(hit)).foregroundStyle(.secondary)
                                    }.font(.caption)
                                    Text(hit.title).font(.system(size:20,weight:.medium,design:.serif)).lineLimit(2)
                                    if !hit.text.isEmpty { Text(hit.text).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,16).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(reader.loading || reader.busy)
                            Divider()
                        }
                    }
                }
                if nodeResults.isEmpty { Text("试试其他关键词。").font(.callout).foregroundStyle(.secondary) }
                if !records.isEmpty { NoteExportButton(reader:reader,records:records,title:"跨书查找结果") }
            } else {
                Text("找到 \(records.count) 条记录").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        ForEach(records) { record in
                            Button {
                                reader.openKnowledgeWorkspace(bookID:record.book.id,noteID:record.note.id)
                                close()
                            } label: {
                                VStack(alignment:.leading,spacing:9) {
                                    Label(record.book.title,systemImage:"book.closed").font(.caption).foregroundStyle(palette.accent)
                                    Text(record.note.title).font(.system(size:20,weight:.medium,design:.serif)).lineLimit(2)
                                    Text(record.note.text.isEmpty ? record.note.quote : record.note.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    Text(record.note.chapter).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,16).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(reader.loading || reader.busy)
                            Divider()
                        }
                    }
                }
                if records.isEmpty { Text("试试其他关键词，或改变记录类型。").font(.callout).foregroundStyle(.secondary) }
                NoteExportButton(reader:reader,records:records,title:"跨书查找结果")
            }
            Spacer(minLength:0)
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(palette.paper)
    }
}
