import Foundation

/// The reader owns this position; a phone or watch never predicts page changes.
public struct ReadingSnapshot: Codable, Equatable {
    public let sessionID: UUID
    public let bookID: UUID
    public let title: String
    public let page: Int
    public let pageCount: Int
    public let locator: String
    public let chapter: String
    public let progress: Double
    public let canGoNext: Bool
    public let canGoPrevious: Bool
    public let readerName: String?
    public let viewportOffset: Double?
    public var supportsFractionalScroll: Bool? = nil
    public var maxScrollLines: Int? = nil
    public var scrollBatchLimit: Double {
        supportsFractionalScroll == true ? Double(min(16,max(4,maxScrollLines ?? 4))) : 4
    }
    public let readingMode: ReadingMode?
    public init(sessionID: UUID, bookID: UUID, title: String, page: Int, pageCount: Int, locator: String = "", chapter: String = "", progress: Double = 0, canGoNext: Bool? = nil, canGoPrevious: Bool? = nil, readingMode: ReadingMode? = nil, viewportOffset: Double? = nil, readerName: String? = nil) {
        self.sessionID = sessionID; self.bookID = bookID; self.title = title
        self.readerName = readerName
        self.viewportOffset = viewportOffset
        self.readingMode = readingMode
        self.page = page; self.pageCount = pageCount
        self.locator = locator; self.chapter = chapter; self.progress = progress
        self.canGoNext = canGoNext ?? (page < pageCount); self.canGoPrevious = canGoPrevious ?? (page > 1)
    }
}

/// Discovery metadata only. This catalog contains no addresses or credentials.
public struct ReadingTarget: Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let kind: String
    public var symbol: String { kind == "ipad" ? "ipad" : (kind == "iphone" ? "iphone" : "desktopcomputer") }
    public init(id: UUID, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
}

public struct WatchTargetRequest: Codable {
    public let id: UUID
    public let targetID: UUID
    public let sentAt: Double
    public init(id: UUID = UUID(), targetID: UUID, sentAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.targetID = targetID; self.sentAt = sentAt
    }
    public func isValid(targets: [ReadingTarget], now: Date = Date()) -> Bool {
        sentAt.isFinite && abs(now.timeIntervalSince1970 - sentAt) <= 10 && targets.contains { $0.id == targetID }
    }
}

/// Only this nonsecret presentation state crosses WatchConnectivity.
public struct PhoneControlState: Codable, Equatable {
    public var receiverID: UUID?
    public var receiverName: String
    public var controlID: UUID?
    public var reading: ReadingSnapshot?
    public var message: String
    public var targets: [ReadingTarget]?
    public var receiverKind: String?
    public var isActive: Bool { controlID != nil && receiverID != nil && reading != nil }
    public init(receiverID: UUID? = nil, receiverName: String = "", controlID: UUID? = nil,
                reading: ReadingSnapshot? = nil, message: String = "在 iPhone 上开始阅读遥控", receiverKind: String? = nil) {
        self.receiverID = receiverID; self.receiverName = receiverName; self.controlID = controlID
        self.reading = reading; self.message = message; self.receiverKind = receiverKind
    }
    public mutating func selectTarget(_ target: ReadingTarget) {
        receiverID = target.id; receiverName = target.name; receiverKind = target.kind
        controlID = nil; reading = nil; message = "已选择 \(target.name)，正在连接…"
    }
    public func accepts(_ request: WatchTurnRequest, now: Date = Date()) -> Bool {
        isActive && request.controlID == controlID && request.receiverID == receiverID &&
        request.command.sessionID == reading?.sessionID && request.command.sentAt.isFinite &&
        abs(now.timeIntervalSince1970 - request.command.sentAt) <= 10
    }
}

public struct WatchTurnRequest: Codable {
    public let controlID: UUID
    public let receiverID: UUID
    public let command: TurnCommand
    public init(controlID: UUID, receiverID: UUID, command: TurnCommand) {
        self.controlID = controlID; self.receiverID = receiverID; self.command = command
    }
}

/// Main-queue-only. A v3 reader deliberately rejects old key-injection commands.
public final class ReadingRouter {
    public let token: String
    public var snapshot: () -> ReadingSnapshot?
    public var readiness: () -> String?
    public var turn: (PageDirection) async -> String?
    public var scroll: ((PageDirection, Double) async -> String?)?
    private var completed: [UUID: (Date, TurnCommand, HTTPResponse)] = [:]
    private var lastTurn: Date?
    private var executing = false
    public init(token: String, snapshot: @escaping () -> ReadingSnapshot?,
                readiness: @escaping () -> String?, turn: @escaping (PageDirection) async -> String?,
                scroll: ((PageDirection, Double) async -> String?)? = nil) {
        self.scroll = scroll
        self.token = token; self.snapshot = snapshot; self.readiness = readiness; self.turn = turn
    }
    public func handle(_ request: HTTPRequest, now: Date = Date()) async -> HTTPResponse {
        guard RequestAuthentication.verify(request, token: token, now: now) else {
            return HTTPResponse(401, Reply(ok: false, message: "连接验证失败，请重新配对"))
        }
        return RequestAuthentication.sign(await route(request, now: now), for: request, token: token)
    }
    private func route(_ request: HTTPRequest, now: Date) async -> HTTPResponse {
        func response(_ status: Int, _ message: String, id: UUID? = nil) -> HTTPResponse {
            var reply = Reply(ok: status == 200, message: message, commandID: id)
            reply.reading = snapshot()
            return HTTPResponse(status, reply)
        }
        if request.method == "GET", request.path == "/v3/status" {
            if snapshot() != nil, let problem = readiness() { return response(409,problem) }
            return response(200, snapshot() == nil ? "请在阅读设备打开一本书" : "阅读器已就绪")
        }
        guard request.method == "POST", request.path == "/v3/turn" else {
            return response(404, "请将 iPhone 与 Apple Watch 更新到新版书籍人生")
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let command = try? JSONDecoder().decode(TurnCommand.self, from: request.body) else {
            return response(400, "无法识别翻页指令")
        }
        if let lines = command.scrollLines, !lines.isFinite || lines < 1.0/16 || lines > 16 { return response(400,"滚动幅度无效",id:command.id) }
        guard command.sentAt.isFinite, abs(now.timeIntervalSince1970 - command.sentAt) <= 10 else {
            return response(408, "操作已过期，请确认书页后再试", id: command.id)
        }
        guard let current = snapshot(), command.sessionID == current.sessionID else {
            return response(409, "阅读内容已改变，请刷新手表后再操作", id: command.id)
        }
        completed = completed.filter { now.timeIntervalSince($0.value.0) < 60 }
        if let previous = completed[command.id] {
            guard previous.1 == command else { return response(409, "指令编号冲突", id: command.id) }
            return previous.2
        }
        if command.scrollLines != nil, current.readingMode != .scroll || scroll == nil {
            return response(409,"请刷新滚动模式或更新阅读器",id:command.id)
        }
        if let lines = command.scrollLines, lines > current.scrollBatchLimit {
            return response(400,"滚动幅度超出阅读器支持范围",id:command.id)
        }
        if let lines = command.scrollLines, lines != lines.rounded(), current.supportsFractionalScroll != true {
            return response(409,"请更新阅读器后使用连续滚动",id:command.id)
        }
        if let problem = readiness() { return response(409, problem, id: command.id) }
        guard !executing else { return response(429, "正在翻页，请稍候", id: command.id) }
        if current.readingMode != .scroll, let lastTurn, now.timeIntervalSince(lastTurn) < 0.35 {
            return response(429, "翻页太快，请稍候", id: command.id)
        }
        let continuous = command.scrollLines != nil && current.supportsFractionalScroll == true
        guard continuous || (command.direction == .next ? current.canGoNext : current.canGoPrevious) else {
            return response(409, command.direction == .next ? "已经是最后一页" : "已经是第一页", id: command.id)
        }
        executing = true
        defer { executing = false }
        let problem: String?
        if let lines = command.scrollLines, let scroll { problem = await scroll(command.direction,lines) }
        else { problem = await turn(command.direction) }
        if let problem { return response(503, problem, id: command.id) }
        let updated = snapshot()
        let movedViewport: Bool
        if let before = current.viewportOffset, let after = updated?.viewportOffset, before.isFinite, after.isFinite {
            movedViewport = abs(after-before) > 0.5
        } else { movedViewport = false }
        // Streaming receivers acknowledge accepted displacement; rendering may
        // continue after the reply. The snapshot still describes real content.
        let acceptedMotion = command.scrollLines != nil && current.supportsFractionalScroll == true
        guard let updated, updated.sessionID == current.sessionID, (acceptedMotion || updated.locator != current.locator || updated.page != current.page || movedViewport) else {
            return response(503, "尚未确认页面变化，请查看阅读设备", id: command.id)
        }
        lastTurn = now
        let result = response(200, acceptedMotion ? "已接收滚动" : "\(updated.chapter) · \(Int(updated.progress * 100))%", id: command.id)
        completed[command.id] = (now, command, result)
        return result
    }
}

extension PhoneControlState {
    /// Status refreshes keep the control ID stable until the reader/session changes.
    /// Only an authenticated snapshot can establish a ready control session.
    public func following(receiverID: UUID, name: String, reading: ReadingSnapshot?, idleMessage: String = "在阅读设备打开一本书即可") -> PhoneControlState {
        let same = self.receiverID == receiverID && self.reading?.sessionID == reading?.sessionID
        return PhoneControlState(receiverID:receiverID,receiverName:name,
            controlID:reading == nil ? nil : (same ? controlID ?? UUID() : UUID()),
            reading:reading,message:reading == nil ? idleMessage : "手表已就绪 · \(reading?.readerName ?? name)")
    }
    public func suspended(_ message: String) -> PhoneControlState {
        PhoneControlState(receiverID:receiverID,receiverName:receiverName,reading:reading,message:message)
    }
    public var targetName: String {
        guard let name = reading?.readerName else { return receiverName }
        return name == "终端" ? "\(receiverName) · 终端" : name
    }
}
