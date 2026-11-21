import Foundation

public enum PageDirection: String, Codable { case next, previous }

public struct TurnCommand: Codable, Equatable {
    public let id: UUID
    public let direction: PageDirection
    public let sentAt: Double
    public let sessionID: UUID?
    public let scrollLines: Double?

    public init(id: UUID = UUID(), direction: PageDirection, sentAt: Double = Date().timeIntervalSince1970, sessionID: UUID? = nil, scrollLines: Double? = nil) {
        self.id = id
        self.direction = direction
        self.sentAt = sentAt
        self.sessionID = sessionID
        self.scrollLines = scrollLines
    }
}

public struct Reply: Codable, Equatable {
    public let ok: Bool
    public let message: String
    public let commandID: UUID?
    public var pairing: PairingChallenge?
    public var encryptedConnection: Data?
    public var reading: ReadingSnapshot?
    public var library: [SharedLibraryBook]?
    public var libraryChunk: LibraryChunk?
    public var progressRecords: [ReadingProgress]?

    public init(ok: Bool, message: String, commandID: UUID? = nil) {
        self.ok = ok
        self.message = message
        self.commandID = commandID
    }
}

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public struct HTTPResponse {
    public let status: Int
    public let reply: Reply
    public var extraHeaders: [String: String] = [:]

    public init(_ status: Int, _ reply: Reply) { self.status = status; self.reply = reply }

    public var body: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(reply)) ?? Data()
    }

    public var data: Data {
        let body = self.body
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 410: "Gone",
                      408: "Request Timeout", 409: "Conflict", 413: "Content Too Large",
                      429: "Too Many Requests", 503: "Service Unavailable"][status] ?? "Error"
        let extra = extraHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n".utf8)
        result.append(body)
        return result
    }
}

/// A bounded, single-request HTTP parser. Chunking, pipelining and duplicate headers are rejected.
public struct HTTPParser {
    public enum Failure: Error { case malformed, tooLarge }
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> HTTPRequest? {
        buffer.append(data)
        guard buffer.count <= 73728 else { throw Failure.tooLarge }
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 8192 else { throw Failure.tooLarge }; return nil
        }
        guard separator.lowerBound <= 8192 else { throw Failure.tooLarge }
        guard let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            throw Failure.malformed
        }
        let lines = header.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2] == "HTTP/1.1" else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), headers[name] == nil else {
                throw Failure.malformed
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["host"] != nil else { throw Failure.malformed }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(lengthText) else { throw Failure.malformed }
        guard length <= (start[1] == "/v3/progress" ? 65536 : 4096) else { throw Failure.tooLarge }
        let received = buffer.count - separator.upperBound
        guard received >= length else { return nil }
        guard received == length else { throw Failure.malformed }
        return HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers,
                           body: Data(buffer[separator.upperBound...]))
    }
}
