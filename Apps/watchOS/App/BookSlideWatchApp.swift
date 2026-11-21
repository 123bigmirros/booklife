import SwiftUI
import WatchKit

@MainActor final class RemoteModel: ObservableObject {
    static let shared = RemoteModel()
    @Published var state = PhoneControlState(message: "请在手表设置中连接阅读设备")
    @Published var connectionMessage = "正在连接阅读设备…"
    private var refreshing = false
    var isForeground = true
    @Published var result: String?
    @Published private(set) var busy = false
    @Published private(set) var crownScrolling = false
    @Published private(set) var actionCount = 0
    private let link = DirectWatchLink.shared
    private var lastScrollHaptic = -Double.infinity
    private var liveMotion = LiveScrollMotion()
    private var scrollTask: Task<Void, Never>?
    private var motionGeneration = UUID()
    private init() {
        link.onContext = { [weak self] state in
            if self?.state.receiverID != state.receiverID || self?.state.controlID != state.controlID ||
                self?.state.reading?.sessionID != state.reading?.sessionID || self?.state.reading?.readingMode != state.reading?.readingMode {
                self?.stopScroll()
            }
            if state.isActive, self?.busy == false { self?.result = nil }
            self?.state = state
            self?.connectionMessage = state.message
        }
        link.onState = { [weak self] in self?.connectionMessage = $0 }
    }
    func stopScroll() { liveMotion.reset(); motionGeneration = UUID() }
    func scroll(_ lines: Double) {
        guard state.isActive, state.reading?.readingMode == .scroll else { return }
        // Retain only fresh, bounded movement during a crown request. A button
        // request never acquires a delayed crown action.
        guard scrollTask != nil || !busy else { return }
        liveMotion.append(lines, now: ProcessInfo.processInfo.systemUptime, maximumLines:state.reading?.scrollBatchLimit ?? 4)
        guard scrollTask == nil else { return }
        let generation = motionGeneration
        crownScrolling = true
        scrollTask = Task {
            defer { liveMotion.reset(); scrollTask = nil; crownScrolling = false }
            while !Task.isCancelled, generation == motionGeneration,
                  let next = liveMotion.take(now: ProcessInfo.processInfo.systemUptime) {
                let reply = await turn(next > 0 ? .next : .previous, scrollLines: abs(next))
                guard reply.ok else { break }
            }
        }
    }
    func refresh() {
        guard !busy, !refreshing, !link.isSynchronizing else { return }
        refreshing = true
        let route = link.routeID
        Task {
            defer { refreshing = false }
            await link.waitForActivation()
            guard route == link.routeID else { return }
            if link.isSynchronizing { return }
            let reply = await request(nil)
            guard route == link.routeID else { return }
            if !reply.ok { state = state.suspended(reply.message); connectionMessage = reply.message }
            else { result = nil }
        }
    }
    func send(_ direction: PageDirection, scrollLines: Double? = nil) {
        stopScroll()
        Task { await turn(direction,scrollLines:scrollLines) }
    }
    func turn(_ direction: PageDirection, scrollLines: Double? = nil) async -> Reply {
        guard !busy, !refreshing else { return Reply(ok: false, message: "正在同步阅读状态，请稍候") }
        let intendedState = state, generation = motionGeneration, route = link.routeID
        actionCount += 1
        busy = true
        result = scrollLines == nil ? (state.reading?.readingMode == .scroll ? "正在滚动…" : "正在翻页…") : nil
        defer { busy = false }
        await link.waitForActivation()
        guard route == link.routeID else { return Reply(ok: false, message: "阅读设备已改变，请重新操作") }
        guard !Task.isCancelled else { return finish(Reply(ok:false,message:"操作已取消")) }
        if scrollLines != nil {
            guard generation == motionGeneration, intendedState.controlID == state.controlID,
                  intendedState.receiverID == state.receiverID,
                  intendedState.reading?.sessionID == state.reading?.sessionID else {
                return Reply(ok:false,message:"阅读状态已改变，请重新转动表冠")
            }
        }
        // Successful replies already carry the current session and position. Avoid
        // a second transport round trip on every reading action.
        // Receivers still reject stale sessions; an issued turn is never retargeted.
        if !state.isActive {
            let refreshed = await request(nil)
            guard route == link.routeID else { return Reply(ok: false, message: "阅读设备已改变，请重新操作") }
            guard refreshed.ok else { return finish(refreshed) }
        }
        guard !Task.isCancelled else { return finish(Reply(ok:false,message:"操作已取消")) }
        if intendedState.isActive,
           intendedState.controlID != state.controlID || intendedState.receiverID != state.receiverID ||
           intendedState.reading?.sessionID != state.reading?.sessionID {
            return finish(Reply(ok: false, message: "阅读目标已改变，请确认后重新操作"))
        }
        guard let controlID = state.controlID, let receiverID = state.receiverID, let reading = state.reading else {
            return finish(Reply(ok:false,message:state.message))
        }
        let command = WatchTurnRequest(controlID:controlID,receiverID:receiverID,
                                       command:TurnCommand(direction:direction,sessionID:reading.sessionID,scrollLines:scrollLines))
        NSLog("BookSlide watch action %@", command.command.id.uuidString)
        let reply = await request(command)
        guard route == link.routeID else { return Reply(ok: false, message: "阅读设备已改变，请确认原设备的书页") }
        NSLog("BookSlide watch acknowledgement %@ ok=%d", command.command.id.uuidString, reply.ok)
        return finish(reply)
    }
    private func request(_ command: WatchTurnRequest?) async -> Reply {
        await withCheckedContinuation { continuation in
            link.request(command) { continuation.resume(returning:$0) }
        }
    }
    private func finish(_ reply: Reply) -> Reply {
        result = reply.ok ? nil : reply.message
        guard isForeground else { return reply }
        // A scrolling stream needs a light detent, not repeated success patterns.
        // Haptics still follow confirmed movement; rapid replies share one pulse.
        if !reply.ok {
            WKInterfaceDevice.current().play(.failure)
        } else if crownScrolling {
            // Continuous crown motion should not feel like a repeated detent.
            // Buttons and page turns retain their confirmed haptic feedback.
        } else if state.reading?.readingMode == .scroll {
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastScrollHaptic >= 0.4 {
                lastScrollHaptic = now
                WKInterfaceDevice.current().play(.click)
            }
        } else {
            WKInterfaceDevice.current().play(.success)
        }
        return reply
    }
}
struct PrimaryGesture: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) { content.handGestureShortcut(.primaryAction) }
        else { content }
    }
}
private enum RemoteScreen { case reader, settings }
struct RemoteView: View {
    @StateObject private var model = RemoteModel.shared
    @ObservedObject private var direct = DirectWatchLink.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @FocusState private var crownFocused: Bool
    @State private var crownValue = 0.0
    @State private var crownInput = CrownPageInput()
    @State private var scrollInput = CrownScrollInput()
    @State private var continuousInput = ContinuousCrownInput()
    @State private var screen = RemoteScreen.reader
    private let green = Color(red:0.31,green:0.46,blue:0.36)
    private var mode: ReadingMode { model.state.reading?.readingMode ?? .paged }
    private var showsDevices: Bool { screen == .settings || !model.state.isActive || direct.pairing }
    private func updateDiscovery() {
        crownFocused = !showsDevices && scenePhase == .active
        if showsDevices, scenePhase == .active { direct.browse() }
        else { direct.stopBrowsing() }
    }
    var body: some View {
        Group {
            if showsDevices { settings } else { reader }
        }
        .containerBackground(Color.black,for:.navigation)
        .onChange(of:scenePhase) { _,phase in
            model.isForeground = phase == .active
            direct.setForeground(phase == .active)
            model.stopScroll()
            crownInput.endRotation(); scrollInput.endRotation(); continuousInput.endRotation()
            updateDiscovery()
            if phase == .active { model.refresh() }
        }
        .onChange(of:showsDevices) { _,_ in
            model.stopScroll()
            crownInput.endRotation(); scrollInput.endRotation(); continuousInput.endRotation()
            updateDiscovery()
        }
        .onChange(of:mode) { _,_ in model.stopScroll(); crownInput.endRotation(); scrollInput.endRotation(); continuousInput.endRotation() }
        .onChange(of:model.state.controlID) { _,_ in
            model.stopScroll(); crownInput.endRotation(); scrollInput.endRotation(); continuousInput.endRotation()
        }
        .onDisappear { model.stopScroll(); direct.stopBrowsing() }
        .onAppear {
            model.isForeground = scenePhase == .active
            direct.setForeground(scenePhase == .active)
            updateDiscovery(); model.refresh()
        }
        .task(id:scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
            }
        }
    }
    private var reader: some View {
        GeometryReader { geometry in
            VStack(spacing:10) {
                Button { screen = .settings } label: {
                    HStack {
                        Text(model.state.targetName).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(minHeight: 32)
                }.buttonStyle(.plain).accessibilityLabel("阅读设备：\(model.state.targetName)，轻点切换")
                // One large native Button: touch and double tap invoke exactly the same action.
                Button {
                    if model.state.isActive { model.send(.next) }
                    else { screen = .settings }
                } label: {
                    VStack(spacing:10) {
                        Text(model.state.reading?.title ?? "等待阅读设备")
                            .font(.system(size:geometry.size.height < 180 ? 16 : 19,weight:.medium,design:.serif))
                            .lineLimit(2).minimumScaleFactor(0.8).privacySensitive()
                        HStack(spacing:6) {
                            if model.busy && !model.crownScrolling && !isLuminanceReduced { ProgressView().controlSize(.small) }
                            Text(model.busy && !model.crownScrolling ? "正在移动" : mode.nextLabel)
                            Image(systemName:mode == .scroll ? "chevron.down" : "chevron.right")
                        }.font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .contentShape(Rectangle())
                    .foregroundStyle(isLuminanceReduced ? Color.white.opacity(0.7) : Color(red:0.89,green:0.91,blue:0.84))
                    .background(isLuminanceReduced ? Color.black : green.opacity(0.22),in:RoundedRectangle(cornerRadius:22))
                }
                .buttonStyle(.plain).modifier(PrimaryGesture())
                .accessibilityLabel(model.state.isActive ? mode.nextLabel : "连接阅读设备").accessibilityHint(model.state.isActive ? "轻点大区域或转动表冠" : "查看连接状态")
                Group {
                    if let result = model.result {
                        Text(result).foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Text(model.state.isActive ? (model.state.reading.map { mode == .scroll ? "\(Int($0.progress * 100))% · 连续滚动" : "\($0.page) / \($0.pageCount) · 本章" } ?? "") : model.state.message)
                            .monospacedDigit().foregroundStyle(.secondary).lineLimit(model.state.isActive ? 1 : 2)
                    }
                }
                .font(.system(size:10)).multilineTextAlignment(.center)
                .frame(maxWidth:.infinity,minHeight:28)
            }.padding(.horizontal,6).padding(.bottom,4)
                .focusable().focused($crownFocused).focusEffectDisabled()
                .digitalCrownRotation($crownValue,from:-1_000_000,through:1_000_000,
                                      sensitivity:.low,isContinuous:false,isHapticFeedbackEnabled:false,
                                      onIdle:{ crownInput.endRotation(); scrollInput.endRotation(); continuousInput.endRotation() })
                .onChange(of:crownValue) { old,value in
                    let enabled = screen == .reader && scenePhase == .active
                    if mode == .scroll {
                        if model.state.reading?.supportsFractionalScroll == true {
                            if let lines = continuousInput.rotate(by:value-old,enabled:enabled && model.state.isActive,maximumLines:model.state.reading?.scrollBatchLimit ?? 4) { model.scroll(lines) }
                        } else if let lines = scrollInput.rotate(by:value-old,enabled:enabled && model.state.isActive) {
                            model.scroll(Double(lines))
                        }
                    } else if let direction = crownInput.rotate(by:value-old,enabled:enabled && !model.busy) {
                        model.send(direction)
                    }
                }
        }
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.state.isActive {
                    Button("返回阅读") { screen = .reader }.buttonStyle(.plain).font(.caption)
                }
                Text("在哪里阅读？").font(.headline)
                if direct.pairing {
                    if let code = direct.comparisonCode {
                        Text(code).font(.title2.monospacedDigit()).frame(maxWidth: .infinity)
                        Text("数字相同后，在阅读设备上允许连接。").font(.caption2).foregroundStyle(.secondary)
                    } else { ProgressView("正在连接…").font(.caption) }
                    Button("取消") { direct.cancelPairing() }
                } else {
                    if let error = direct.pairingError {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                    if direct.authenticated, let name = direct.rememberedDeviceName, !model.state.isActive {
                        Label("已连接 \(name)", systemImage: "checkmark.circle").font(.caption)
                        Text("在这台设备打开一本书，就能开始阅读。").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("附近设备").font(.caption2).foregroundStyle(.secondary)
                    ForEach(direct.devices) { device in
                        deviceButton(device, remembered: direct.rememberedDevices.contains { $0.id == device.id })
                    }
                    Text(direct.discoveryMessage).font(.caption2).foregroundStyle(.secondary)
                    if direct.rememberedDevices.contains(where: { saved in !direct.devices.contains { $0.id == saved.id } }) {
                        Text("已保存").font(.caption2).foregroundStyle(.secondary)
                        ForEach(direct.rememberedDevices.filter { saved in !direct.devices.contains { $0.id == saved.id } }) { device in
                            deviceButton(device, remembered: true)
                        }
                    }
                    Text("首次连接：在 iPad 或 Mac 打开“手表遥控”，再点设备名称。").font(.caption2).foregroundStyle(.secondary)
                    Button("重新查找") { direct.searchAgain() }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
    }
    private func deviceButton(_ device: DirectWatchLink.Device, remembered: Bool) -> some View {
        Button {
            model.stopScroll(); direct.select(device.id); screen = .reader
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.caption).lineLimit(2)
                    if remembered {
                        Text(device.id == direct.selectedDeviceID ? (direct.authenticated ? "已连接" : "\(direct.message)") : "点按连接")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if device.id == direct.selectedDeviceID, direct.authenticated { Image(systemName: "checkmark").font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.accessibilityLabel("\(device.name)，\(remembered ? "已保存，点按连接" : "首次连接")")
        .contextMenu {
            if remembered { Button("重新配对") { direct.repair(device.id); screen = .reader } }
        }
    }

}
@main
struct BookSlideWatchApp: App {
    var body: some Scene { WindowGroup { NavigationStack { RemoteView() }.navigationTitle("") } }
}
