import Foundation
import UniformTypeIdentifiers
#if os(macOS) || os(iOS)
import PDFKit
#endif

/// A shared presentation contract: submitting via keyboard and button is identical.
public enum ReaderSearchState: Equatable {
    case idle, searching, complete(Int), failed
    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var message: String? {
        switch self {
        case .idle: return "输入关键词后搜索书中内容"
        case .searching: return "正在搜索…"
        case .complete(0): return "没有找到相关内容，试试其他关键词"
        case .complete(let count) where count >= 80: return "显示前 80 条结果，可缩小关键词范围"
        case .complete: return nil
        case .failed: return "搜索未完成，请重试"
        }
    }
}

public enum BookFormat: String, CaseIterable {
    case epub, pdf

    public init?(filename: String) {
        self.init(rawValue: (filename as NSString).pathExtension.lowercased())
    }

    public var contentType: UTType {
        switch self {
        case .epub: return .epub
        case .pdf: return .pdf
        }
    }

    public var label: String { rawValue.uppercased() }
}

public enum BookImportFile {
    public static let maximumSize = 50 * 1024 * 1024
    public enum Failure: LocalizedError {
        case format, size, invalid(BookFormat), lockedPDF
        public var errorDescription: String? {
            switch self {
            case .format: return "请选择 EPUB 或 PDF 文件"
            case .size: return "请选择 50 MB 以内的书籍文件"
            case .invalid(let format): return "文件不是有效的 \(format.label)"
            case .lockedPDF: return "PDF 需要密码，请先解锁文件再导入"
            }
        }
    }
    public static func read(_ url: URL) throws -> Data {
        guard let format = BookFormat(filename: url.lastPathComponent) else { throw Failure.format }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumSize else { throw Failure.size }
        let data = try Data(contentsOf: url)
        try validate(data, as: format)
        return data
    }

    public static func validate(_ data: Data, as format: BookFormat) throws {
        guard !data.isEmpty, data.count <= maximumSize else { throw Failure.size }
        switch format {
        case .epub:
            // The script-isolated EPUB reader validates the package itself.
            guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw Failure.invalid(format) }
        case .pdf:
            #if os(macOS) || os(iOS)
            _ = try pdfDocument(data)
            #else
            throw Failure.format
            #endif
        }
    }

    #if os(macOS) || os(iOS)
    public static func pdfDocument(_ data: Data) throws -> PDFDocument {
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil,
              let document = PDFDocument(data: data) else { throw Failure.invalid(.pdf) }
        guard !document.isLocked else { throw Failure.lockedPDF }
        guard document.pageCount > 0, document.page(at: 0) != nil else { throw Failure.invalid(.pdf) }
        return document
    }
    #endif

    public static func fingerprint(_ data: Data) -> String {
        ReadingProgress.bookKey(package: data)
    }
}

public enum PDFPageLocator {
    private static let prefix = "pdf:page:"

    public static func encode(_ index: Int) -> String { prefix + String(index + 1) }

    public static func index(_ locator: String, pageCount: Int) -> Int? {
        guard locator.hasPrefix(prefix), let page = Int(locator.dropFirst(prefix.count)),
              page > 0, page <= pageCount, locator == encode(page - 1) else { return nil }
        return page - 1
    }
}

/// Text offsets in a PDF page's own text layer. Page addresses stay compatible
/// with saved bookmarks, notes and terminal progress.
public enum PDFTextLocator {
    public struct Span: Equatable {
        public let page: Int
        public let range: NSRange
        public init(page: Int, range: NSRange) { self.page = page; self.range = range }
    }

    public static func encode(_ spans: [Span]) -> String? {
        guard let first = spans.first, spans.count <= 128, first.page >= 0, first.page < Int.max,
              spans.allSatisfy({ $0.page >= 0 && $0.range.location >= 0 && $0.range.length > 0 &&
                                 $0.range.location <= Int.max - $0.range.length }) else { return nil }
        return PDFPageLocator.encode(first.page) + "#text:" + spans.map {
            "\($0.page):\($0.range.location):\($0.range.length)"
        }.joined(separator: ";")
    }

    public static func decode(_ locator: String) -> [Span]? {
        guard locator.utf8.count <= 8192, let separator = locator.range(of: "#text:") else { return nil }
        var spans: [Span] = []
        for value in locator[separator.upperBound...].split(separator: ";", omittingEmptySubsequences: false) {
            let parts = value.split(separator: ":")
            guard parts.count == 3, let page = Int(parts[0]), let start = Int(parts[1]), let length = Int(parts[2]) else { return nil }
            spans.append(Span(page:page,range:NSRange(location:start,length:length)))
        }
        return encode(spans) == locator ? spans : nil
    }
}
