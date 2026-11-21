import Foundation

/// Call from one serial queue. Commands expire, never queue for a later reading session,
/// and repeated IDs never dispatch a second key event.
public final class CommandRouter {
    public var token: String
    public var readiness: () -> String?
    public var execute: (PageDirection) -> String?
    public var statusMessage: () -> String = { "已连接，可以翻页" }
    public var successMessage: () -> String = { "已发送翻页按键" }
    private var completed: [UUID: (Date, PageDirection, HTTPResponse)] = [:]
    private var lastExecution: Date?
    private var failedAuth: [Date] = []

    public init(token: String, readiness: @escaping () -> String?, execute: @escaping (PageDirection) -> String?) {
        self.token = token; self.readiness = readiness; self.execute = execute
    }

    public func handle(_ request: HTTPRequest, now: Date = Date()) -> HTTPResponse {
        func failure(_ status: Int, _ message: String, id: UUID? = nil) -> HTTPResponse {
            HTTPResponse(status, Reply(ok: false, message: message, commandID: id))
        }
        failedAuth.removeAll { now.timeIntervalSince($0) >= 60 }
        guard RequestAuthentication.verify(request, token: token, now: now) else {
            if failedAuth.count >= 10 { return failure(429, "配对失败次数过多，请稍后重试") }
            failedAuth.append(now)
            return failure(401, "连接验证失败，请在 iPhone 重新连接 Mac")
        }
        return RequestAuthentication.sign(handleAuthenticated(request, now: now), for: request, token: token)
    }

    private func handleAuthenticated(_ request: HTTPRequest, now: Date) -> HTTPResponse {
        func failure(_ status: Int, _ message: String, id: UUID? = nil) -> HTTPResponse {
            HTTPResponse(status, Reply(ok: false, message: message, commandID: id))
        }
        if request.method == "GET", request.path == "/v1/status" {
            if let problem = readiness() { return failure(409, problem) }
            return HTTPResponse(200, Reply(ok: true, message: statusMessage()))
        }
        guard request.method == "POST", request.path == "/v1/turn" else {
            return failure(404, "不支持的请求")
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let command = try? JSONDecoder().decode(TurnCommand.self, from: request.body) else {
            return failure(400, "翻页指令格式不正确")
        }
        completed = completed.filter { now.timeIntervalSince($0.value.0) < 60 }
        if let previous = completed[command.id] {
            guard previous.1 == command.direction else { return failure(409, "指令编号冲突", id: command.id) }
            return previous.2
        }
        guard command.sentAt.isFinite, abs(now.timeIntervalSince1970 - command.sentAt) <= 10 else {
            return failure(408, "指令已过期，请重试并检查设备时间", id: command.id)
        }
        if let last = lastExecution, now.timeIntervalSince(last) < 0.35 {
            return failure(429, "翻页太快，请稍候", id: command.id)
        }
        if let problem = readiness() { return failure(409, problem, id: command.id) }
        if let problem = execute(command.direction) { return failure(503, problem, id: command.id) }
        lastExecution = now
        let response = HTTPResponse(200, Reply(ok: true, message: successMessage(), commandID: command.id))
        completed[command.id] = (now, command.direction, response)
        return response
    }
}
