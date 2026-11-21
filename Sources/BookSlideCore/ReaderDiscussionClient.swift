import Foundation

public enum ReaderDiscussionError: LocalizedError, Equatable {
    case missingKey, lunaUnavailable, http(Int), invalidResponse, incomplete, tooLong
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "请先在 AI 设置中添加 DeepSeek API Key。"
        case .lunaUnavailable: return "无法连接 Codex Luna。请检查 Codex 登录或桥接地址，也可在 AI 设置中配置备用 DeepSeek。"
        case .http(400), .http(413), .http(422): return "AI 服务无法处理本次请求，请缩小选文或调整问题后重试。"
        case .http(401), .http(403): return "DeepSeek 密钥无效或没有访问权限，请检查 AI 设置。"
        case .http(402): return "DeepSeek 账户余额不足，请充值后重试。"
        case .http(429): return "请求较多，请稍后重试。"
        case .http: return "AI 服务暂时不可用，请稍后重试。"
        case .invalidResponse: return "未能读取 AI 回答，请重试。"
        case .incomplete: return "回答中断，已保留收到的内容。可以重试。"
        case .tooLong: return "回答达到长度上限，已保留内容。请缩小问题后继续。"
        }
    }
}

public struct ReaderDiscussionClient {
    public static let model = "deepseek-flash"
    public static let endpoint = URL(string:"https://api.deepseek.com/chat/completions")!
    public let endpoint: URL
    private let apiKey: String
    private let usesLuna: Bool
    public init(apiKey: String, endpoint: URL = Self.endpoint, usesLuna: Bool = false) {
        self.apiKey = apiKey; self.endpoint = endpoint; self.usesLuna = usesLuna
    }

    public func urlRequest(messages: [ReaderChatMessage]) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ReaderDiscussionError.missingKey }
        var request = URLRequest(url:endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = usesLuna ? 55 : 90
        request.setValue("Bearer \(apiKey)",forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        request.httpBody = try JSONEncoder().encode(Body(messages:messages,
            model:usesLuna ? ReaderAIProvider.luna.model : Self.model, thinking:usesLuna ? nil : ["type":"disabled"]))
        return request
    }
    private struct Body: Encodable {
        var messages: [ReaderChatMessage]
        let model: String
        let stream = true
        let max_tokens = 2048
        let thinking: [String:String]?
    }
    private struct Event: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta
            var finish_reason: String?
        }
        var choices: [Choice]
    }

    /// A missing terminal event is an interruption, never a completed answer.
    public func stream(messages: [ReaderChatMessage], session: URLSession? = nil,
                       onText: @escaping @MainActor (String) throws -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = usesLuna ? 55 : 90
        configuration.timeoutIntervalForResource = usesLuna ? 60 : 180
        let connection = session ?? URLSession(configuration:configuration,delegate:ReaderAIDirectConnection(),delegateQueue:nil)
        defer { if session == nil { connection.invalidateAndCancel() } }
        let (bytes,response) = try await connection.bytes(for:urlRequest(messages:messages))
        guard let http = response as? HTTPURLResponse else { throw ReaderDiscussionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ReaderDiscussionError.http(http.statusCode) }
        var received = false, finished = false, limited = false, length = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let value = String(line.dropFirst(5)).trimmingCharacters(in:.whitespaces)
            if value == "[DONE]" { finished = true; break }
            guard let event = try? JSONDecoder().decode(Event.self,from:Data(value.utf8)) else { throw ReaderDiscussionError.invalidResponse }
            if let choice = event.choices.first {
                if choice.finish_reason == "length" { limited = true }
                if let delta = choice.delta.content, !delta.isEmpty {
                    received = true; length += delta.count
                    guard length <= 32000 else { throw ReaderDiscussionError.tooLong }
                    try await onText(delta)
                }
            }
        }
        if limited { throw ReaderDiscussionError.tooLong }
        guard finished else { throw ReaderDiscussionError.incomplete }
        guard received else { throw ReaderDiscussionError.invalidResponse }
    }
}

private final class ReaderAIDirectConnection: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum ReaderAIProvider: String {
    case luna = "Codex Luna"
    case deepSeek = "DeepSeek V4.1 Flash"

    public var model: String { self == .luna ? "gpt-6-luna" : ReaderDiscussionClient.model }
}

/// A fallback is a new request, so only start it if Luna was unavailable
/// before the reader received any answer.
public struct ReaderAIService {
    public typealias Output = @MainActor (String) throws -> Void
    public typealias Stream = @MainActor ([ReaderChatMessage], @escaping Output) async throws -> Void
    private let luna: Stream
    private let deepSeek: Stream?

    public init(luna: @escaping Stream, deepSeek: Stream?) {
        self.luna = luna; self.deepSeek = deepSeek
    }

    @MainActor public func stream(messages: [ReaderChatMessage],
                                  onProvider: (ReaderAIProvider) -> Void,
                                  onText: @escaping Output) async throws {
        var received = false
        try Task.checkCancellation()
        onProvider(.luna)
        do {
            try await luna(messages) { text in
                try Task.checkCancellation()
                guard !text.isEmpty else { return }
                received = true
                try onText(text)
            }
        } catch {
            try Task.checkCancellation()
            guard !received, Self.cannotConnect(error) else { throw error }
            guard let deepSeek else { throw ReaderDiscussionError.lunaUnavailable }
            onProvider(.deepSeek)
            try await deepSeek(messages,onText)
        }
    }

    private static func cannotConnect(_ error: Error) -> Bool {
        switch error as? ReaderDiscussionError {
        case .lunaUnavailable: return true
        case .http(502), .http(503), .http(504), .http(500): return true
        default: break
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut,.cannotFindHost,.cannotConnectToHost,.dnsLookupFailed,.networkConnectionLost,
                .notConnectedToInternet,.secureConnectionFailed,.serverCertificateUntrusted,
                .serverCertificateHasBadDate,.serverCertificateHasUnknownRoot,.serverCertificateNotYetValid].contains(error.code)
    }
}
