import Foundation
import UIKit
import Combine

/// One persistent coordinator for foreground reading and WatchConnectivity wakes.
/// Pair once; status recovery never replays a turn or selects an unpaired device.
final class PhoneRelay: ObservableObject {
    static let shared = PhoneRelay()
    @Published private(set) var state = PhoneControlState(message:"正在连接阅读设备…")
    @Published private(set) var busy = false
    @Published private(set) var enabled = !UserDefaults.standard.bool(forKey:"watchControlPaused")
    private let session = ReceiverClient.session()
    private let link = WatchLink.shared
    private let key = "phoneControlStateV3"
    private var refreshTask: Task<Void,Never>?
    private var generation = 0
    private var preferRemote = false
    private var lastLocalSession: UUID?
    private weak var localReader: ReaderModel?
    private let localID: UUID = {
        let key = "phoneReaderReceiverID"
        let id = UserDefaults.standard.string(forKey:key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(id.uuidString,forKey:key)
        return id
    }()
    var isLocal: Bool { state.receiverID == localID }
    func configureLocal(_ reader: ReaderModel) {
        localReader = reader
        reader.onReadingChanged = { [weak self] in self?.updateLocal() }
        updateLocal()
        Task { @MainActor in await refresh() }
    }
    func startLocal() {
        guard UIDevice.current.userInterfaceIdiom != .pad, !busy else { return }
        setEnabled(true); preferRemote = false; generation += 1
        updateLocal()
    }
    private func updateLocal() {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        let reading = localReader?.snapshot
        if let reading, reading.sessionID != lastLocalSession {
            lastLocalSession = reading.sessionID; preferRemote = false; generation += 1
        }
        guard enabled else { return }
        if !preferRemote, let reading {
            state = state.following(receiverID:localID,name:"iPhone",reading:reading)
            if UIApplication.shared.applicationState != .active { state = state.suspended("回到 iPhone 阅读页面即可继续") }
            publish()
        } else if isLocal, reading == nil {
            generation += 1; state = PhoneControlState(message:"正在连接阅读设备…"); publish()
            Task { @MainActor in await refresh() }
        }
    }
    private init() {
        if let data = UserDefaults.standard.data(forKey:key),
           let saved = try? JSONDecoder().decode(PhoneControlState.self,from:data) {
            // Persisted presentation is not proof that a reader is still reachable.
            state = saved.suspended(enabled ? "正在恢复连接…" : "手表遥控已暂停")
            preferRemote = saved.receiverID != localID
        }
        link.contextProvider = { [weak self] in self?.state ?? PhoneControlState() }
        link.contextRefresh = { [weak self] completion in
            let background = UIApplication.shared.beginBackgroundTask(withName:"BookSlide reconnect")
            Task { @MainActor in
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                await self?.refresh(); completion()
            }
        }
        link.commandHandler = { [weak self] request, completion in
            guard let self else { completion(Reply(ok:false,message:"iPhone 正在准备连接")); return }
            let background = UIApplication.shared.beginBackgroundTask(withName:"BookSlide page turn")
            Task { @MainActor in
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                completion(await self.forward(request))
            }
        }
    }
    private func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(!value,forKey:"watchControlPaused")
    }
    private func publish() {
        UserDefaults.standard.set(try? JSONEncoder().encode(state),forKey:key)
        link.publishConnection()
    }
    @MainActor func refresh() async {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        if let refreshTask { await refreshTask.value; return }
        let task = Task { @MainActor in await self.refreshStatus() }
        refreshTask = task; await task.value; refreshTask = nil
    }
    @MainActor private func refreshStatus() async {
        guard enabled else { state = state.suspended("手表遥控已暂停"); publish(); return }
        guard !busy else { return }
        if !preferRemote, localReader?.snapshot != nil { updateLocal(); return }
        PhoneModel.shared.startDiscovery()
        guard let connection = try? ConnectionStore.loadRemote() else {
            state = PhoneControlState(message:"首次使用：在 iPhone 添加阅读设备，之后自动连接")
            publish(); return
        }
        let revision = generation
        do {
            let reply: Reply
            do { reply = try await ReceiverClient.send(connection:connection,command:nil,session:session) }
            catch {
                // Discovery may have authenticated a changed address while the old
                // endpoint failed. Retry status only, never a reading command.
                if let recovered = try? ConnectionStore.loadRemote(), recovered.receiverID == connection.receiverID,
                   recovered.endpoint != connection.endpoint {
                    reply = try await ReceiverClient.send(connection:recovered,command:nil,session:session)
                } else { throw error }
            }
            guard enabled, !busy, revision == generation,
                  (try? ConnectionStore.loadRemote())?.receiverID == connection.receiverID else { return }
            if reply.ok {
                state = state.following(receiverID:connection.receiverID,name:connection.name,reading:reply.reading)
            } else { state = state.suspended(reply.message) }
            publish()
        } catch {
            guard revision == generation, enabled else { return }
            state = PhoneControlState(receiverID:connection.receiverID,receiverName:connection.name,
                message:"正在重连 \(connection.name) · 请保持阅读设备的书籍人生打开")
            publish()
        }
    }
    func resetConnection(_ connection: SavedConnection) {
        setEnabled(true); preferRemote = true; generation += 1
        state = PhoneControlState(receiverID:connection.receiverID,receiverName:connection.name,message:"正在连接 \(connection.name)…")
        publish(); Task { @MainActor in await refresh(); if !state.isActive { await refresh() } }
    }
    func stop() {
        setEnabled(false); generation += 1
        state = state.suspended("手表遥控已暂停"); publish()
    }
    @MainActor func resume() async {
        guard !busy else { return }
        setEnabled(true); generation += 1
        if isLocal { preferRemote = false }
        await refresh()
    }
    @MainActor func start() async {
        guard !busy else { return }
        setEnabled(true); preferRemote = true; generation += 1
        await refresh()
    }
    @discardableResult @MainActor func send(_ direction: PageDirection) async -> Reply {
        if !state.isActive { await refresh() }
        guard let controlID = state.controlID, let receiverID = state.receiverID, let reading = state.reading else {
            return Reply(ok:false,message:state.message)
        }
        return await forward(WatchTurnRequest(controlID:controlID,receiverID:receiverID,
            command:TurnCommand(direction:direction,sessionID:reading.sessionID)))
    }
    @MainActor private func forward(_ request: WatchTurnRequest) async -> Reply {
        guard enabled else { return Reply(ok:false,message:"手表遥控已暂停",commandID:request.command.id) }
        if isLocal { return await forwardLocal(request) }
        guard state.accepts(request), let connection = try? ConnectionStore.loadRemote(), connection.receiverID == request.receiverID else {
            await refresh()
            return Reply(ok:false,message:"已更新阅读状态，请再操作一次",commandID:request.command.id)
        }
        guard !busy else { return Reply(ok:false,message:"正在移动，请稍候",commandID:request.command.id) }
        generation += 1; let revision = generation
        busy = true; defer { busy = false }
        do {
            let reply = try await ReceiverClient.send(connection:connection,command:request.command,session:session)
            guard enabled, generation == revision, state.controlID == request.controlID else {
                return Reply(ok:false,message:"阅读设备已切换",commandID:request.command.id)
            }
            // A stale-session rejection includes the authenticated new session.
            // Adopt it for the next action; do not replay this issued command.
            if reply.ok || (reply.reading != nil && reply.reading?.sessionID != request.command.sessionID) {
                state = state.following(receiverID:connection.receiverID,name:connection.name,reading:reply.reading)
            } else { state = state.suspended(reply.message) }
            publish()
            if !reply.ok, reply.reading?.sessionID != request.command.sessionID, reply.reading != nil {
                var changed = Reply(ok:false,message:"已跟随新的阅读内容，请再操作一次",commandID:request.command.id)
                changed.reading = reply.reading; return changed
            }
            return reply
        } catch {
            if generation == revision {
                state = state.suspended("连接中断，正在自动恢复…"); publish()
            }
            return Reply(ok:false,message:"未确认这次操作，请查看书页；连接将自动恢复",commandID:request.command.id)
        }
    }
    @MainActor private func forwardLocal(_ request: WatchTurnRequest) async -> Reply {
        func reply(_ ok: Bool,_ message: String) -> Reply {
            var result = Reply(ok:ok,message:message,commandID:request.command.id)
            result.reading = localReader?.snapshot; return result
        }
        guard state.accepts(request), let reader = localReader,
              reader.snapshot?.sessionID == request.command.sessionID else {
            updateLocal(); return reply(false,"已更新阅读状态，请再操作一次")
        }
        guard UIApplication.shared.applicationState == .active else {
            state = state.suspended("回到 iPhone 阅读页面即可继续"); publish()
            return reply(false,state.message)
        }
        guard !busy else { return reply(false,"正在移动，请稍候") }
        generation += 1; busy = true; defer { busy = false }
        if let lines = request.command.scrollLines, (!lines.isFinite || lines < 1.0/16 || lines > 16 || !reader.isScrolling) { return reply(false,"已更新阅读模式，请再操作一次") }
        if let error = await reader.turn(request.command.direction,scrollLines:request.command.scrollLines) { return reply(false,error) }
        guard state.controlID == request.controlID else { return reply(false,"阅读设备已切换") }
        updateLocal(); return reply(true,reader.position?.chapter ?? "已移动")
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        _ = PhoneRelay.shared; return true
    }
}
