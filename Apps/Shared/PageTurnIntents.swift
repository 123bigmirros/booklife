import AppIntents

private struct PageTurnIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Shared intent identities let an iPhone-created shortcut execute on the watch.
/// Foreground execution on Watch wakes the app; it does not require the reader
/// screen to have remained frontmost, nor start a fake workout to stay alive.
struct NextPageIntent: AppIntent {
    static var title: LocalizedStringResource = "下一页"
    static var description = IntentDescription("让书籍人生当前正在遥控的书籍翻到下一页。")
    static var openAppWhenRun: Bool {
        #if os(watchOS)
        true
        #else
        false
        #endif
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await performPageTurn(.next)
        return .result()
    }
}

struct PreviousPageIntent: AppIntent {
    static var title: LocalizedStringResource = "上一页"
    static var description = IntentDescription("让书籍人生当前正在遥控的书籍翻回上一页。")
    static var openAppWhenRun: Bool { NextPageIntent.openAppWhenRun }

    @MainActor func perform() async throws -> some IntentResult {
        try await performPageTurn(.previous)
        return .result()
    }
}

@MainActor private func performPageTurn(_ direction: PageDirection) async throws {
    let reply: Reply
    #if os(watchOS)
    reply = await RemoteModel.shared.turn(direction)
    #else
    let relay = PhoneRelay.shared
    await relay.refresh()
    try Task.checkCancellation()
    reply = await relay.send(direction)
    #endif
    guard reply.ok else { throw PageTurnIntentError(message: reply.message) }
}

struct ReadingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextPageIntent(), phrases: ["用\(.applicationName)翻到下一页"],
                    shortTitle: "下一页", systemImageName: "chevron.right")
        AppShortcut(intent: PreviousPageIntent(), phrases: ["用\(.applicationName)翻到上一页"],
                    shortTitle: "上一页", systemImageName: "chevron.left")
    }
}
