import Foundation
import CryptoKit
#if canImport(BookSlideCore)
import BookSlideCore
#endif

public struct CatalogBook {
    public let url: URL
    public let title: String
    public let author: String
    public let lastRead: Date
    public var source = "书籍人生"
}
public enum LibraryCatalog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BookSlide/Library",isDirectory:true)
    }
    public static var recentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BookSlide/Terminal/Recent",isDirectory:true)
    }
    private struct Entry: Decodable {
        let filename: String, title: String, author: String
        let lastRead: Date
        let locator: String?
        let hidden: Bool?
        let sourcePath: String?
    }
    public static var appleBooksDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Mobile Documents/iCloud~com~apple~iBooks/Documents",
                "Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books"].map { home.appendingPathComponent($0,isDirectory:true) }
    }
    private static func recentFile(_ url: URL, in directory: URL) -> URL {
        let key = SHA256.hash(data:Data(url.standardizedFileURL.path.utf8)).map { String(format:"%02x",$0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    private static func readDate(_ url: URL, in directory: URL) -> Date {
        (try? JSONDecoder().decode(Date.self,from:Data(contentsOf:recentFile(url,in:directory)))) ?? .distantPast
    }
    public static func allBooks(appleDirectories: [URL] = appleBooksDirectories, bookSlideDirectory: URL = directory, recentDirectory: URL = recentDirectory) throws -> [CatalogBook] {
        var result = try books(in:bookSlideDirectory,recentDirectory:recentDirectory)
        let metadata = try? Data(contentsOf:bookSlideDirectory.appendingPathComponent("library.json"))
        let entries = metadata.flatMap { try? JSONDecoder().decode([Entry].self,from:$0) } ?? []
        let hiddenPaths = Set(entries.filter { $0.hidden == true }.compactMap(\.sourcePath))
        var seen = Set(result.map { $0.url.resolvingSymlinksInPath().path })
        for directory in appleDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) else { continue }
            for url in files where BookFormat(filename:url.lastPathComponent) != nil {
                guard !hiddenPaths.contains(url.path) else { continue }
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let metadataURL = url.appendingPathComponent("iTunesMetadata.plist")
                let metadata = (try? Data(contentsOf:metadataURL)).flatMap { try? PropertyListSerialization.propertyList(from:$0,format:nil) as? [String:Any] }
                var book = CatalogBook(url:url,title:metadata?["itemName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                       author:metadata?["artistName"] as? String ?? "",lastRead:readDate(url,in:recentDirectory))
                book.source = "Apple Books"; result.append(book)
            }
        }
        return result.sorted { $0.lastRead == $1.lastRead ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.lastRead > $1.lastRead }
    }
    public static func books(in directory: URL = directory, recentDirectory: URL = recentDirectory) throws -> [CatalogBook] {
        guard FileManager.default.fileExists(atPath:directory.path) else { return [] }
        let manifest = directory.appendingPathComponent("library.json")
        let entries = FileManager.default.fileExists(atPath:manifest.path) ? try JSONDecoder().decode([Entry].self,from:Data(contentsOf:manifest)) : []
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { BookFormat(filename:$0.lastPathComponent) != nil }
        return files.compactMap { url -> CatalogBook? in
            let entry = entries.first { $0.filename == url.lastPathComponent }
            guard entry?.hidden != true else { return nil }
            let recent = recentDirectory.appendingPathComponent(url.lastPathComponent + ".json")
            let cliDate = max(readDate(url,in:recentDirectory),(try? JSONDecoder().decode(Date.self,from:Data(contentsOf:recent))) ?? .distantPast)
            let appDate = entry?.locator?.isEmpty == false ? entry!.lastRead : .distantPast
            return CatalogBook(url:url,title:entry?.title ?? url.deletingPathExtension().lastPathComponent,author:entry?.author ?? "",lastRead:max(appDate,cliDate))
        }.sorted { $0.lastRead == $1.lastRead ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.lastRead > $1.lastRead }
    }
    public static func markRead(_ url: URL, at date: Date = Date(), recentDirectory: URL = recentDirectory) throws {
        try FileManager.default.createDirectory(at:recentDirectory,withIntermediateDirectories:true)
        try JSONEncoder().encode(date).write(to:recentFile(url,in:recentDirectory),options:.atomic)
    }
}
