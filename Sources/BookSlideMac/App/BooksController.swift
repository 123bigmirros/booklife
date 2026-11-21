import AppKit
import ApplicationServices
#if canImport(BookSlideCore)
import BookSlideCore
#endif

enum BooksController {
    static let bundleIdentifiers = ["com.apple.iBooksX", "com.apple.iBooks"]

    static func readiness() -> String? {
        guard AXIsProcessTrusted() else { return "请先在 Mac 授予书籍人生辅助功能权限" }
        guard let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundleIdentifiers.contains(identifier) else {
            return "请把 Mac 上的 Apple Books 阅读窗口切到前台"
        }
        return nil
    }

    static func turn(_ direction: PageDirection) -> String? {
        // Recheck immediately before posting. Never type into a different foreground app.
        if let problem = readiness() { return problem }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier, bundleIdentifiers.contains(identifier),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: direction == .next ? 124 : 123, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: direction == .next ? 124 : 123, keyDown: false) else {
            return "无法创建翻页按键"
        }
        down.flags = []; up.flags = []
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        // Posting an event has no page-change acknowledgement from Apple Books.
        return nil
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
