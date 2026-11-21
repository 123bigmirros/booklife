import Foundation

public struct SharedLibraryBook: Codable, Equatable {
    public let id: UUID
    public let title: String
    public let author: String
    public let lastRead: Date
    public let cover: Data?
    public let progressKey: String?
    public let formatIdentifier: String?
    public init(id: UUID, title: String, author: String, lastRead: Date, cover: Data? = nil, progressKey: String? = nil, format: BookFormat = .epub) {
        self.id = id; self.title = title; self.author = author; self.lastRead = lastRead; self.cover = cover
        self.progressKey = progressKey
        formatIdentifier = format == .epub ? nil : format.rawValue
    }
    public var format: BookFormat? { BookFormat(rawValue: formatIdentifier ?? "epub") }
}
public struct LibraryChunk: Codable, Equatable {
    public let id: UUID
    public let offset: Int
    public let total: Int
    public let data: Data
}
/// Only catalog IDs are accepted. Filesystem paths never cross this API.
public final class LibraryRouter {
    public static let chunkSize = 512 * 1024
    public static let maximumSize = BookImportFile.maximumSize
    private let token: String
    private let catalog: () -> [SharedLibraryBook]
    private let archive: @MainActor (UUID) async throws -> Data
    private var cached: (UUID, Data, Date)?
    public init(token: String, catalog: @escaping () -> [SharedLibraryBook], archive: @escaping @MainActor (UUID) async throws -> Data) {
        self.token = token; self.catalog = catalog; self.archive = archive
    }
    public func handle(_ request: HTTPRequest) async -> HTTPResponse? {
        guard request.path == "/v3/library" || request.path.hasPrefix("/v3/library/") else { return nil }
        guard RequestAuthentication.verify(request,token:token) else { return HTTPResponse(401,Reply(ok:false,message:"连接验证失败")) }
        func result(_ status: Int, _ reply: Reply) -> HTTPResponse {
            RequestAuthentication.sign(HTTPResponse(status,reply),for:request,token:token)
        }
        guard request.method == "GET" else { return result(400,Reply(ok:false,message:"请求方式无效")) }
        if request.path == "/v3/library" {
            var reply = Reply(ok:true,message:"书库已更新"); reply.library = catalog()
            return result(200,reply)
        }
        let parts = request.path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count == 5, let id = UUID(uuidString:String(parts[3])), let offset = Int(parts[4]), offset >= 0,
              catalog().contains(where: { $0.id == id }) else { return result(404,Reply(ok:false,message:"书籍不在 Mac 书库中")) }
        do {
            let data: Data
            if let cache = cached, cache.0 == id, Date().timeIntervalSince(cache.2) < 120 { data = cache.1 }
            else { data = try await archive(id); cached = nil }
            guard !data.isEmpty, data.count <= Self.maximumSize, offset < data.count else { return result(413,Reply(ok:false,message:"书籍大小或下载位置无效")) }
            cached = (id,data,Date())
            var reply = Reply(ok:true,message:"正在下载")
            reply.libraryChunk = LibraryChunk(id:id,offset:offset,total:data.count,data:data.subdata(in:offset..<min(data.count,offset+Self.chunkSize)))
            return result(200,reply)
        } catch { return result(503,Reply(ok:false,message:"Mac 无法读取书籍：\(error.localizedDescription)")) }
    }
}
