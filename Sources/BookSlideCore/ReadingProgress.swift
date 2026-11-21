import Foundation
import CryptoKit

/// A content anchor, independent of screen size, page count and viewing mode.
public struct ContentAnchor: Codable, Equatable {
    public var href: String
    public var quote: String
    public var fraction: Double
    public init(href: String, quote: String, fraction: Double) {
        self.href = href; self.quote = quote; self.fraction = fraction
    }
    public static func canonical(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) &&
            ![0x202A,0x202B,0x202C,0x202D,0x202E,0x2066,0x2067,0x2068,0x2069].contains($0.value)
        }))
    }
}

public struct ReadingProgress: Codable, Equatable, Identifiable {
    public let id: UUID
    public let bookKey: String
    public let deviceID: UUID
    public let deviceName: String
    public let updatedAt: Date
    public let anchor: ContentAnchor
    public let cfi: String?
    public let progress: Double
    public init(id: UUID = UUID(), bookKey: String, deviceID: UUID, deviceName: String, updatedAt: Date = Date(), anchor: ContentAnchor, cfi: String? = nil, progress: Double) {
        self.id = id; self.bookKey = bookKey; self.deviceID = deviceID; self.deviceName = deviceName
        self.updatedAt = updatedAt; self.anchor = anchor; self.cfi = cfi; self.progress = progress
    }
    public func isNewer(than other: Self) -> Bool {
        updatedAt != other.updatedAt ? updatedAt > other.updatedAt : id.uuidString > other.id.uuidString
    }
    public var isValid: Bool {
        bookKey.count == 64 && bookKey.allSatisfy { $0.isHexDigit } && deviceName.count <= 100 &&
        anchor.href.count <= 2048 && !anchor.href.isEmpty && anchor.quote.count <= 160 &&
        anchor.fraction.isFinite && (0...1).contains(anchor.fraction) && progress.isFinite && (0...1).contains(progress) &&
        (cfi?.count ?? 0) < 8192 && updatedAt.timeIntervalSince1970.isFinite && updatedAt <= Date().addingTimeInterval(300)
    }
    public static func bookKey(package: Data) -> String { SHA256.hash(data:package).map { String(format:"%02x",$0) }.joined() }
}

/// Each source owns one file per book. File coordination protects GUI / CLI
/// access; cloud providers never have to merge two devices' writes to one file.
#if !os(watchOS)
public final class ProgressStore {
    public let directory: URL
    public static var defaultDirectory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BookSlide/Progress",isDirectory:true)
    }
    public init(directory: URL = defaultDirectory) {
        self.directory = directory
        #if os(macOS)
        if directory.standardizedFileURL == Self.defaultDirectory.standardizedFileURL {
            try? migrateLegacyCloudFolder(Self.defaultCloudDirectory)
        }
        #endif
    }
    /// Only installations with existing local progress inherit the old folder.
    /// The marker also prevents reconnecting a folder after the user disconnects it.
    public func migrateLegacyCloudFolder(_ legacy: URL) throws {
        let marker = directory.appendingPathComponent("cloud-configuration-v31")
        guard !FileManager.default.fileExists(atPath:marker.path) else { return }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []
        // Before this migration Mac always used the implicit legacy folder,
        // even when an older, possibly expired bookmark existed beside it.
        // Explicit choices in this version write the marker and are never replaced.
        if existing.contains(where: { $0.hasSuffix(".device") || $0.hasSuffix(".json") }),
           FileManager.default.fileExists(atPath:legacy.path) {
            let old = directory.appendingPathComponent("cloud-folder.bookmark")
            let backup = directory.appendingPathComponent("legacy-cloud-folder.bookmark")
            if FileManager.default.fileExists(atPath:old.path), !FileManager.default.fileExists(atPath:backup.path) {
                try FileManager.default.copyItem(at:old,to:backup)
            }
            try selectCloudFolder(legacy)
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data().write(to:marker,options:.atomic)
    }
    public func records() throws -> [ReadingProgress] {
        guard FileManager.default.fileExists(atPath:directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey]).filter { $0.pathExtension == "json" }.prefix(10000).compactMap { file in
            guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) < 32768 else { return nil }
            var coordinationError: NSError?, result: ReadingProgress?
            NSFileCoordinator().coordinate(readingItemAt:file,options:[],error:&coordinationError) { url in
                if let data = try? Data(contentsOf:url), let record = try? JSONDecoder().decode(ReadingProgress.self,from:data), record.isValid { result = record }
            }
            if let coordinationError { throw coordinationError }
            return result
        }
    }
    public func latest(bookKey: String) throws -> ReadingProgress? {
        try records().filter { $0.bookKey == bookKey }.max { $1.isNewer(than:$0) }
    }
    public func merge(_ records: [ReadingProgress]) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for record in records where record.isValid {
            let file = directory.appendingPathComponent(record.bookKey + "." + record.deviceID.uuidString + ".json")
            var coordinationError: NSError?, writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt:file,options:.forReplacing,error:&coordinationError) { url in
                do {
                    if let data = try? Data(contentsOf:url), let saved = try? JSONDecoder().decode(ReadingProgress.self,from:data), !record.isNewer(than:saved) { return }
                    try JSONEncoder().encode(record).write(to:url,options:.atomic)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError as NSError? { throw error }
        }
    }
    public func deviceID(source: String) throws -> UUID {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file = directory.appendingPathComponent(source + ".device")
        if let text = try? String(contentsOf:file), let id = UUID(uuidString:text) { return id }
        let id = UUID(); try id.uuidString.write(to:file,atomically:true,encoding:.utf8); return id
    }
    public func selectCloudFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = .minimalBookmark
        #endif
        let data = try url.bookmarkData(options:options,includingResourceValuesForKeys:nil,relativeTo:nil)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:directory.appendingPathComponent("cloud-folder.bookmark"),options:.atomic)
        try Data().write(to:directory.appendingPathComponent("cloud-configuration-v31"),options:.atomic)
    }
    #if os(macOS)
    public static var defaultCloudDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/summary/share",isDirectory:true)
    }
    #endif
    public var cloudConfigured: Bool {
        return FileManager.default.fileExists(atPath:directory.appendingPathComponent("cloud-folder.bookmark").path)
    }
    public var cloudFolderName: String? { (try? bookmarkedCloudFolder())?.lastPathComponent }
    public func disconnectCloud() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data().write(to:directory.appendingPathComponent("cloud-configuration-v31"),options:.atomic)
        let bookmark = directory.appendingPathComponent("cloud-folder.bookmark")
        if FileManager.default.fileExists(atPath:bookmark.path) { try FileManager.default.removeItem(at:bookmark) }
    }
    /// This confirms local file exchange only. iCloud controls upload/download timing.
    public func syncCloud() throws {
        guard cloudConfigured else { return }
        let url = try bookmarkedCloudFolder()
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let cloud = ProgressStore(directory:url.appendingPathComponent("BookSlideProgress-v1",isDirectory:true))
        if let files = try? FileManager.default.contentsOfDirectory(at:cloud.directory,includingPropertiesForKeys:[.isUbiquitousItemKey]) {
            for file in files where (try? file.resourceValues(forKeys:[.isUbiquitousItemKey]).isUbiquitousItem) == true { try? FileManager.default.startDownloadingUbiquitousItem(at:file) }
        }
        try merge(cloud.records())
        try cloud.merge(records())
    }
    private func bookmarkedCloudFolder() throws -> URL {
        let data = try Data(contentsOf:directory.appendingPathComponent("cloud-folder.bookmark"))
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope,.withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData:data,options:options,relativeTo:nil,bookmarkDataIsStale:&stale)
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if stale { try selectCloudFolder(url) }
        return url
    }
}

public final class ProgressRouter {
    private let token: String
    private let store: ProgressStore
    public init(token: String, store: ProgressStore) { self.token = token; self.store = store }
    public func handle(_ request: HTTPRequest) -> HTTPResponse? {
        guard request.path == "/v3/progress" else { return nil }
        guard RequestAuthentication.verify(request,token:token) else { return HTTPResponse(401,Reply(ok:false,message:"连接验证失败")) }
        var reply: Reply
        do {
            guard request.method == "POST", let records = try? JSONDecoder().decode([ReadingProgress].self,from:request.body), records.count <= 20, records.allSatisfy(\.isValid) else {
                return RequestAuthentication.sign(HTTPResponse(400,Reply(ok:false,message:"进度数据无效")),for:request,token:token)
            }
            try store.merge(records)
            reply = Reply(ok:true,message:"阅读进度已交换")
            reply.progressRecords = try store.records()
        } catch { reply = Reply(ok:false,message:"进度暂未同步，已保留本机记录") }
        return RequestAuthentication.sign(HTTPResponse(reply.ok ? 200 : 503,reply),for:request,token:token)
    }
}
#endif
