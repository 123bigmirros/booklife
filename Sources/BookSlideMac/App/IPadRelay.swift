import Foundation
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Uses the user's existing Focus shortcut. Acceptance is not a page-change acknowledgement.
/// All methods and callbacks run on the main queue, like HTTPServer's command handler.
final class IPadRelay {
    static let shortcutName = "BookSlide 手表翻下一页"
    var onState: ((String) -> Void)?
    private var process: Process?
    private var timeout: DispatchWorkItem?
    private var nextAllowed = Date.distantPast

    func cancel() {
        timeout?.cancel(); timeout = nil
        let child = process
        process = nil
        if child?.isRunning == true { child?.terminate() }
    }

    func readiness() -> String? {
        if process != nil { return "正在发送 iPad 指令，请稍候" }
        if Date() < nextAllowed { return "等待 iPad 同步，请看到翻页后再操作" }
        return nil
    }

    func turn(_ direction: PageDirection) -> String? {
        guard direction == .next else { return "iPad 中转目前只支持下一页" }
        if let error = readiness() { return error }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        child.arguments = ["run", Self.shortcutName]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self, weak child] _ in
            DispatchQueue.main.async {
                guard let self, let child, self.process === child else { return }
                self.timeout?.cancel(); self.timeout = nil; self.process = nil
                self.onState?(child.terminationStatus == 0
                    ? "已发出 iPad 翻页信号；请以 iPad 页码为准"
                    : "iPad 指令运行失败，请在 Mac 快捷指令中检查“\(Self.shortcutName)”")
            }
        }
        process = child
        do { try child.run() }
        catch { process = nil; return "无法启动 Mac 快捷指令：\(error.localizedDescription)" }
        // Focus sync may be delayed. Never retry or queue additional page turns.
        nextAllowed = Date().addingTimeInterval(5)
        let deadline = DispatchWorkItem { [weak self, weak child] in
            guard let self, let child, self.process === child else { return }
            self.process = nil; self.timeout = nil
            if child.isRunning { child.terminate() }
            self.onState?("iPad 指令超时，未自动重试；请查看 iPad 页码")
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        return nil
    }
}
