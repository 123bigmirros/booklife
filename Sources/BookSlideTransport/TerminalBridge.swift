#if os(macOS)
import Foundation
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// A short-lived, same-user rendezvous. This never contains the Mac pairing key.
public struct TerminalLease: Codable {
    public let owner: UUID
    public let port: UInt16
    public let token: String
    public let expires: Date
    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BookSlide/Terminal/active-reader.json")
    }
    public init(owner: UUID, port: UInt16, token: String, now: Date = Date()) {
        self.owner = owner; self.port = port; self.token = token; self.expires = now.addingTimeInterval(6)
    }
    public func save(to file: URL = Self.file) throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let data = try JSONEncoder().encode(self)
        guard FileManager.default.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at:temporary) }
        if FileManager.default.fileExists(atPath:file.path) { _ = try FileManager.default.replaceItemAt(file,withItemAt:temporary) }
        else { try FileManager.default.moveItem(at:temporary,to:file) }
    }
    public static func load(from file: URL = Self.file, now: Date = Date()) -> TerminalLease? {
        guard let data = try? Data(contentsOf:file), let lease = try? JSONDecoder().decode(Self.self,from:data),
              lease.port > 0, lease.token.count == 32, lease.expires > now, lease.expires.timeIntervalSince(now) <= 7 else { return nil }
        return lease
    }
    public static func remove(owner: UUID, from file: URL = Self.file) {
        guard load(from:file)?.owner == owner else { return }
        try? FileManager.default.removeItem(at:file)
    }
}

public final class TerminalBridge {
    private let token: String
    private let lease: () -> TerminalLease?
    private let session = ReceiverClient.session()
    public init(token: String, lease: @escaping () -> TerminalLease? = { TerminalLease.load() }) { self.token = token; self.lease = lease }
    public func handle(_ request: HTTPRequest) async -> HTTPResponse? {
        guard ["/v3/status","/v3/turn"].contains(request.path), let lease = lease() else { return nil }
        guard RequestAuthentication.verify(request,token:token) else { return HTTPResponse(401,Reply(ok:false,message:"连接验证失败")) }
        func result(_ status: Int, _ reply: Reply) -> HTTPResponse {
            RequestAuthentication.sign(HTTPResponse(status,reply),for:request,token:token)
        }
        do {
            // The endpoint is always loopback; a lease cannot redirect requests onto the network.
            var forwarded = URLRequest(url:URL(string:"http://127.0.0.1:\(lease.port)\(request.path)")!)
            forwarded.httpMethod = request.method
            if !request.body.isEmpty { forwarded.httpBody = request.body }
            forwarded.setValue("application/json",forHTTPHeaderField:"Content-Type")
            let headers = RequestAuthentication.headers(method:request.method,path:request.path,body:request.body,token:lease.token)
            headers.forEach { forwarded.setValue($0.value,forHTTPHeaderField:$0.key) }
            let (data,response) = try await session.data(for:forwarded)
            guard let http = response as? HTTPURLResponse,
                  RequestAuthentication.verifyResponse(status:http.statusCode,body:data,signature:http.value(forHTTPHeaderField:"X-BookSlide-Signature"),nonce:headers["x-bookslide-nonce"]!,token:lease.token) else { throw ReceiverClient.Failure.authentication }
            let reply = try JSONDecoder().decode(Reply.self,from:data)
            return result(http.statusCode,reply)
        } catch {
            // Never send a failed terminal command to the GUI reader as a fallback.
            let command = try? JSONDecoder().decode(TurnCommand.self,from:request.body)
            return result(503,Reply(ok:false,message:"终端未响应，请确认终端正文已打开",commandID:command?.id))
        }
    }
}
#endif
