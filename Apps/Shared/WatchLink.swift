#if os(iOS)
import Foundation
import WatchConnectivity

/// Compatibility for previously installed phone clients; current Watch uses DirectWatchLink only.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    var onContext: ((PhoneControlState) -> Void)?
    var onState: ((String) -> Void)?
    var contextProvider: (() -> PhoneControlState)?
    var contextRefresh: ((@escaping () -> Void) -> Void)?
    var commandHandler: ((WatchTurnRequest, @escaping (Reply) -> Void) -> Void)?
    private var session: WCSession?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session; session.delegate = self; session.activate()
    }
    func publishConnection(updated: Bool = false) {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(payload())
            onState?(session.isWatchAppInstalled ? "阅读状态已同步给系统" : "请在 Apple Watch 安装书籍人生")
            if session.isReachable {
                session.sendMessage(payload(), replyHandler: nil, errorHandler: { _ in })
            }
        } catch { onState?("等待手表连接") }
    }
    private func payload() -> [String: Any] {
        let state = contextProvider?() ?? PhoneControlState()
        return ["version": 3, "state": (try? JSONEncoder().encode(state)) ?? Data()]
    }
    private func accept(_ payload: [String: Any]) {
        guard payload["version"] as? Int == 3, let data = payload["state"] as? Data,
              let state = try? JSONDecoder().decode(PhoneControlState.self, from: data) else { return }
        onContext?(state)
    }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.publishConnection()
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.publishConnection()
        }
    }
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.accept(context) }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.accept(message) }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { replyHandler([:]); return }
            guard message["version"] as? Int == 3 else { replyHandler(self.payload()); return }
            if message["request"] as? String == "turn",
               let data = message["command"] as? Data,
               let command = try? JSONDecoder().decode(WatchTurnRequest.self, from: data), let handler = self.commandHandler {
                handler(command) { reply in
                    var result = self.payload(); result["reply"] = try? JSONEncoder().encode(reply)
                    replyHandler(result)
                }
            } else if let refresh = self.contextRefresh { refresh { replyHandler(self.payload()) } }
            else { replyHandler(self.payload()) }
        }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

#endif
