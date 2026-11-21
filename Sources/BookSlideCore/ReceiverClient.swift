import Foundation

public enum ReceiverClient {
    public enum Failure: LocalizedError {
        case invalidAddress, invalidResponse, authentication
        public var errorDescription: String? {
            switch self {
            case .invalidAddress: return "连接信息无效，请重新连接这台阅读设备"
            case .invalidResponse: return "阅读设备返回了无法识别的响应"
            case .authentication: return "无法验证阅读设备，请检查设备时间或重新连接"
            }
        }
    }
    public static func send(connection: SavedConnection, direction: PageDirection?, session: URLSession) async throws -> Reply {
        try await send(connection: connection, command: direction.map { TurnCommand(direction: $0) }, session: session, version: "v1")
    }
    public static func send(connection: SavedConnection, command: TurnCommand?, session: URLSession, version: String = "v3") async throws -> Reply {
        guard let base = SavedConnection.localURL(connection.endpoint) else { throw Failure.invalidAddress }
        let path = "/\(version)/" + (command == nil ? "status" : "turn")
        let body = try command.map { try JSONEncoder().encode($0) } ?? Data()
        let method = command == nil ? "GET" : "POST"
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        if command != nil { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let headers = RequestAuthentication.headers(method: method, path: path, body: body, token: connection.token)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard RequestAuthentication.verifyResponse(status: http.statusCode, body: data,
            signature: http.value(forHTTPHeaderField: "X-BookSlide-Signature"), nonce: headers["x-bookslide-nonce"]!, token: connection.token) else { throw Failure.authentication }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard !reply.ok || reply.commandID == command?.id else { throw Failure.invalidResponse }
        return reply
    }
    public static func library(connection: SavedConnection, book: UUID? = nil, offset: Int = 0, session: URLSession) async throws -> Reply {
        guard let base = SavedConnection.localURL(connection.endpoint) else { throw Failure.invalidAddress }
        let path = "/v3/library" + (book.map { "/\($0.uuidString)/\(offset)" } ?? "")
        var request = URLRequest(url:base.appendingPathComponent(String(path.dropFirst())))
        let headers = RequestAuthentication.headers(method:"GET",path:path,token:connection.token)
        headers.forEach { request.setValue($0.value,forHTTPHeaderField:$0.key) }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, data.count <= 8 * 1024 * 1024 else { throw Failure.invalidResponse }
        guard RequestAuthentication.verifyResponse(status:http.statusCode,body:data,signature:http.value(forHTTPHeaderField:"X-BookSlide-Signature"),nonce:headers["x-bookslide-nonce"]!,token:connection.token) else { throw Failure.authentication }
        return try JSONDecoder().decode(Reply.self,from:data)
    }
    public static func progress(connection: SavedConnection, records: [ReadingProgress], session: URLSession) async throws -> [ReadingProgress] {
        guard let base = SavedConnection.localURL(connection.endpoint) else { throw Failure.invalidAddress }
        let path = "/v3/progress", body = try JSONEncoder().encode(records)
        var request = URLRequest(url:base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let headers = RequestAuthentication.headers(method:"POST",path:path,body:body,token:connection.token)
        headers.forEach { request.setValue($0.value,forHTTPHeaderField:$0.key) }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, data.count < 8 * 1024 * 1024,
              RequestAuthentication.verifyResponse(status:http.statusCode,body:data,signature:http.value(forHTTPHeaderField:"X-BookSlide-Signature"),nonce:headers["x-bookslide-nonce"]!,token:connection.token) else { throw Failure.authentication }
        let reply = try JSONDecoder().decode(Reply.self,from:data)
        guard reply.ok, let records = reply.progressRecords else { throw Failure.invalidResponse }
        return records
    }
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
    public static func librarySession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration:config)
    }
}
