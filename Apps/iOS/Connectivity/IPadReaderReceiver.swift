import SwiftUI
import UIKit

/// The iPad accepts the same authenticated commands over direct BLE and optional LAN.
final class IPadReaderReceiver: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var running = false
    @Published private(set) var message = "正在准备接收"
    @Published private(set) var bluetoothMessage = "正在准备蓝牙…"
    @Published private(set) var bluetoothReady = false
    @Published private(set) var pairingOpen = false
    @Published private(set) var pending: PairingCoordinator.Pending?
    let name = "iPad · " + String(UIDevice.current.name.prefix(50))
    private let reader: ReaderModel
    private let receiverID: UUID
    private var token = ""
    private var port: UInt16 = 8765
    private var server: HTTPServer?
    private var bluetooth: BluetoothReceiver?
    private var timer: Timer?
    private lazy var pairing = PairingCoordinator(receiverID: receiverID) { [weak self] in
        guard let self, (self.running || self.bluetoothReady), !self.token.isEmpty else { return nil }
        // The client replaces this transport hint with the resolved Bonjour address
        // and authenticates it before saving, just as it does for Mac receivers.
        return SavedConnection(receiverID: self.receiverID, name: self.name,
            endpoint: "http://bookslide-ipad.local:\(self.port)", token: self.token, deviceKind: "ipad")
    }

    init(reader: ReaderModel) {
        self.reader = reader
        receiverID = UserDefaults.standard.string(forKey: "ipadReceiverID").flatMap(UUID.init(uuidString:)) ?? UUID()
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        UserDefaults.standard.set(receiverID.uuidString, forKey: "ipadReceiverID")
        enabled = !UserDefaults.standard.bool(forKey: "ipadRemotePaused")
        do {
            token = try PairingStore.load(account: "ipad-reader") ?? PairingStore.generate()
            try PairingStore.save(token, account: "ipad-reader")
        } catch { message = "请解锁 iPad 后重新打开书籍人生"; bluetoothMessage = message }
        pairing.onChange = { [weak self] in
            guard let self else { return }
            self.pairingOpen = self.pairing.isOpen; self.pending = self.pairing.pending
        }
    }

    func resume() {
        guard UIDevice.current.userInterfaceIdiom == .pad, enabled, bluetooth == nil, !token.isEmpty else { return }
        let router = ReadingRouter(token: token, snapshot: { [weak reader] in reader?.snapshot }, readiness: { [weak reader] in
            guard UIApplication.shared.applicationState == .active,
                  reader?.readingWindow?.windowScene?.activationState == .foregroundActive else {
                return "请保持 iPad 阅读页面亮屏并处于前台"
            }
            guard reader?.snapshot != nil else { return "请先在 iPad 打开一本书" }
            return nil
        }, turn: { [weak reader] direction in
            guard let reader else { return "阅读器已关闭" }
            return await reader.turn(direction)
        }, scroll: { [weak reader] direction, lines in
            guard let reader else { return "阅读器已关闭" }
            return await reader.turn(direction, scrollLines: lines)
        })
        let progress = ProgressRouter(token: token, store: reader.progressStore)
        let handler: (HTTPRequest) async -> HTTPResponse = { [weak self] request in
            guard let self, self.enabled else { return HTTPResponse(409, Reply(ok: false, message: "iPad 遥控已停止")) }
            if let reply = self.pairing.handle(request) { return reply }
            if let reply = progress.handle(request) { return reply }
            return await router.handle(request)
        }
        let bluetooth = BluetoothReceiver(handler: handler)
        bluetooth.onState = { [weak self] in self?.bluetoothMessage = $0 }
        bluetooth.onAvailability = { [weak self] in self?.bluetoothReady = $0 }
        self.bluetooth = bluetooth
        bluetooth.start(name: name)
        let server = HTTPServer(handler: handler)
        server.onState = { [weak self] text, port in
            guard let self else { return }
            self.running = port != nil
            if let port { self.port = port; self.message = "已开启接收 · 请保持 iPad 阅读页面在前台" }
            else {
                self.message = text
                if text.hasPrefix("启动失败") { self.server = nil }
            }
        }
        self.server = server
        do { try server.start(port: 8765, serviceName: name, receiverID: receiverID, deviceKind: "ipad") }
        catch { self.server = nil; message = "无法启动接收：\(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pairing.expire() }
    }

    func enable() {
        enabled = true; UserDefaults.standard.set(false,forKey:"ipadRemotePaused"); resume()
    }
    func beginPairing() {
        enable()
        guard bluetooth != nil else { return }
        pairing.begin()
    }
    func approve(_ id: UUID) {
        if pairing.approve(id: id) { message = "已配对 · 打开书籍后手表自动连接" }
        else { message = "连接尚未就绪，请稍后重新确认" }
    }
    func cancelPairing() { pairing.clear() }
    func suspend() {
        pairing.clear(); timer?.invalidate(); timer = nil
        bluetooth?.stop(); bluetooth = nil; bluetoothReady = false
        server?.stop(); server = nil; running = false
        // Invalidate requests issued before backgrounding, even when the book stays open.
        if enabled { reader.invalidateSession() }
        message = enabled ? "已暂停 · 回到 iPad 后恢复接收" : "已停止手表遥控"
    }
    func stop() {
        suspend(); enabled = false
        UserDefaults.standard.set(true, forKey: "ipadRemotePaused")
        message = "已停止手表遥控"
    }
}

struct IPadRemoteSetup: View {
    @ObservedObject var receiver: IPadReaderReceiver
    @Environment(\.dismiss) private var dismiss
    @State private var approved = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(receiver.name, systemImage: "ipad").font(.headline)
                    if receiver.bluetoothReady {
                        Text(approved ? "已允许连接" : "在手表上选择这台 iPad")
                            .font(.title3.weight(.medium))
                        Text(approved ? "打开一本书，就能用表冠前后滚动。" : "打开手表的书籍人生，轻点“\(receiver.name)”。")
                            .foregroundStyle(.secondary)
                    } else { Text(receiver.bluetoothMessage).foregroundStyle(.secondary) }
                }
                if let pending = receiver.pending {
                    Section("\(pending.clientName) 想连接") {
                        Text(pending.code).font(.system(.largeTitle, design: .monospaced)).tracking(5)
                            .accessibilityLabel("配对码 \(pending.code.map(String.init).joined(separator: " "))")
                        Text("确认与手表上的数字相同。")
                        Button("数字一致，允许连接") {
                            receiver.approve(pending.id)
                            approved = !receiver.pairingOpen
                        }.disabled(!receiver.bluetoothReady)
                        Button("拒绝", role: .cancel) { receiver.cancelPairing() }
                    }
                } else if !receiver.pairingOpen && !approved {
                    Section {
                        Button("重新等待手表") { receiver.beginPairing() }
                    }
                }
                Section {
                    Text("只需首次确认。以后打开两端书籍人生，选择这台 iPad 即可；切换到 Mac 也会保留这里的连接。")
                    Text("阅读时保持 iPad 亮屏，手表在附近。")
                }.font(.callout).foregroundStyle(.secondary)
            }
            .navigationTitle("手表遥控").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(approved ? "去阅读" : "完成") { dismiss() } } }
            .onAppear { receiver.beginPairing() }
            .onDisappear { if receiver.pairingOpen { receiver.cancelPairing() } }
        }.tint(readingAccent)
    }
}
