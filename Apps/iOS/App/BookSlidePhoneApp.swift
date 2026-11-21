import SwiftUI
import Foundation
import CryptoKit
import UIKit

struct NearbyReader: Identifiable, Equatable {
    let id: UUID
    let name: String
    let endpoint: String
    let deviceKind: String
    var symbol: String { deviceKind == "ipad" ? "ipad" : "desktopcomputer" }
}

final class PhoneModel: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = PhoneModel()
    @Published var nearby: [NearbyReader] = []
    @Published var connection: SavedConnection?
    @Published var message = "正在查找附近的阅读设备…"
    @Published var watchState = "等待 Apple Watch…"
    @Published var comparisonCode: String?
    @Published var selectedName = ""
    @Published var isPairing = false
    @Published var testing = false
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var resolved: [String: NearbyReader] = [:]
    private let session = ReceiverClient.session()
    private let link = WatchLink.shared
    private var pairingTask: Task<Void, Never>?
    private var browsing = false
    private var refreshing: Set<UUID> = []

    override init() {
        super.init()
        connection = try? ConnectionStore.loadRemote()
        browser.delegate = self
        link.onState = { [weak self] in self?.watchState = $0 }
    }
    func startDiscovery() {
        connection = try? ConnectionStore.loadRemote()
        guard !browsing else { return }
        browsing = true; message = "正在查找附近的阅读设备…"
        browser.searchForServices(ofType: "_bookslide._tcp.", inDomain: "local.")
        link.publishConnection()
    }
    func stopDiscovery() {
        browser.stop(); browsing = false
        services.values.forEach { $0.stop() }; services.removeAll(); resolved.removeAll(); nearby = []
        cancelPairing()
    }
    func rescan() { stopDiscovery(); startDiscovery() }
    private func key(_ service: NetService) -> String { service.name + service.type + service.domain }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = key(service); services[id] = service; service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = key(service); services[id]?.stop(); services[id] = nil; resolved[id] = nil; updateNearby()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        browsing = false
        message = "无法发现阅读设备，请允许本地网络访问，并确认两台设备连接同一 Wi-Fi。"
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        guard services[key(service)] === service, let rawHost = service.hostName, let txt = service.txtRecordData() else { return }
        let record = NetService.dictionary(fromTXTRecord: txt)
        guard let idData = record["id"], let idString = String(data: idData, encoding: .utf8), let id = UUID(uuidString: idString),
              let version = record["version"], String(data: version, encoding: .utf8) == "2" else { return }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let endpoint = "http://\(host):\(service.port)"
        guard SavedConnection.localURL(endpoint) != nil else { return }
        let kind = record["kind"].flatMap { String(data: $0, encoding: .utf8) } ?? "mac"
        if UIDevice.current.userInterfaceIdiom == .pad && kind == "ipad" { return }
        let mac = NearbyReader(id: id, name: service.name, endpoint: endpoint, deviceKind: kind)
        resolved[key(service)] = mac; updateNearby()
        refreshSavedEndpoint(mac)
    }
    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        message = "发现了设备，但尚未连接成功；请刷新重试。"
    }
    private func updateNearby() {
        nearby = Dictionary(resolved.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name < $1.name }
        if !isPairing { message = nearby.isEmpty ? "请在 Mac 或 iPad 打开书籍人生，点击“连接新设备”。" : "选择 Mac 或 iPad，在阅读设备上确认即可。" }
    }
    private func refreshSavedEndpoint(_ mac: NearbyReader) {
        guard let old = connection, old.receiverID == mac.id, !refreshing.contains(mac.id) else { return }
        refreshing.insert(mac.id)
        Task { @MainActor in
            defer { self.refreshing.remove(mac.id) }
            var updated = old; updated.endpoint = mac.endpoint
            do {
                // Authenticate the discovery result before replacing the saved address.
                _ = try await ReceiverClient.send(connection: updated, command: nil, session: session)
                guard self.connection?.receiverID == old.receiverID, self.connection?.token == old.token else { return }
                try ConnectionStore.saveRemote(updated)
                if updated.deviceKind != "ipad" { try ConnectionStore.save(updated) }
                self.connection = updated
                link.publishConnection(updated: updated != old)
                if updated != old { await PhoneRelay.shared.refresh() }
            } catch { /* Do not replace a trusted address with an unverified advertisement. */ }
        }
    }
    func pair(_ mac: NearbyReader) {
        guard !isPairing else { return }
        if let connection, connection.receiverID == mac.id { selectSavedMac(connection); return }
        isPairing = true; selectedName = mac.name; comparisonCode = nil
        message = "正在与阅读设备建立连接…"
        pairingTask = Task { @MainActor in
            defer { self.isPairing = false; self.comparisonCode = nil }
            do {
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let hello = PairingHello(id: UUID(), clientName: UIDevice.current.userInterfaceIdiom == .pad ? "我的 iPad" : "我的 iPhone", publicKey: privateKey.publicKey.rawRepresentation)
                let initial = try await pairingRequest(mac, path: "start", body: JSONEncoder().encode(hello))
                try Task.checkCancellation()
                guard initial.ok, let challenge = initial.pairing, challenge.id == hello.id, challenge.receiverID == mac.id else {
                    message = initial.message; return
                }
                let key = try PairingCrypto.key(privateKey: privateKey, remote: challenge.publicKey,
                    clientPublic: hello.publicKey, serverPublic: challenge.publicKey, id: hello.id, receiverID: mac.id)
                comparisonCode = PairingCrypto.comparisonCode(key)
                message = "确认阅读设备显示相同数字，然后在阅读设备点击允许连接。"
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let reply = try await pairingRequest(mac, path: "poll", body: JSONEncoder().encode(PairingPoll(id: hello.id)))
                    try Task.checkCancellation()
                    if let envelope = reply.encryptedConnection {
                        var saved = try PairingCrypto.open(envelope, key: key, id: hello.id)
                        guard saved.receiverID == mac.id, saved.isValid else { throw ReceiverClient.Failure.invalidResponse }
                        // Use the successfully resolved Bonjour hostname, not a changing IPv4 address.
                        saved.endpoint = mac.endpoint
                        _ = try await ReceiverClient.send(connection: saved, command: nil, session: session)
                        try Task.checkCancellation()
                        try ConnectionStore.saveRemote(saved)
                        if saved.deviceKind != "ipad" { try ConnectionStore.save(saved) }
                        connection = saved
                        PhoneRelay.shared.resetConnection(saved)
                        message = "已配对 \(saved.name)，打开书籍后手表会自动就绪。"
                        return
                    }
                    if reply.message != "等待 Mac 确认" { message = reply.message; return }
                }
                message = "等待确认已超时，请重新连接"
            } catch is CancellationError { message = "已取消连接" }
            catch { message = "连接未完成：\(error.localizedDescription)" }
        }
    }
    private func pairingRequest(_ mac: NearbyReader, path: String, body: Data) async throws -> Reply {
        guard let base = SavedConnection.localURL(mac.endpoint) else { throw ReceiverClient.Failure.invalidAddress }
        var request = URLRequest(url: base.appendingPathComponent("v2/pair/" + path))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Reply.self, from: data)
    }
    func cancelPairing() { pairingTask?.cancel(); pairingTask = nil }
    func selectSavedMac(_ saved: SavedConnection) {
        do {
            try ConnectionStore.saveRemote(saved); connection = saved
            PhoneRelay.shared.resetConnection(saved)
        } catch { message = "无法切换设备：\(error.localizedDescription)" }
    }
    func sync() { link.publishConnection() }
    func testConnection() {
        guard let connection, !testing else { return }
        testing = true
        Task { @MainActor in
            defer { self.testing = false }
            do { message = try await ReceiverClient.send(connection: connection, command: nil, session: session).message }
            catch { message = error.localizedDescription }
        }
    }
}

struct PhoneRemoteView: View {
    @ObservedObject private var model = PhoneModel.shared
    @ObservedObject private var relay = PhoneRelay.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDevices = false
    private let accent = readingAccent
    var body: some View {
        NavigationStack {
            List {
                Section("手机 / iPad 阅读") {
                    Text("在手表的“连接设置 → 阅读设备”中选择“iPhone / iPad”。")
                        .font(.callout).foregroundStyle(.secondary)
                    if relay.isLocal || model.connection != nil {
                        Label(relay.isLocal ? "这台 iPhone" : model.connection?.name ?? "阅读设备",
                              systemImage:relay.isLocal ? "iphone" : model.connection?.deviceKind == "ipad" ? "ipad" : "desktopcomputer")
                        if relay.state.isActive, let reading = relay.state.reading {
                            Text(reading.title).font(.headline)
                            Text(reading.chapter).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(relay.state.message).font(.callout).foregroundStyle(.secondary)
                    if !relay.enabled {
                        Button("恢复自动连接") { Task { await relay.resume() } }
                    } else if relay.isLocal, let connection = model.connection {
                        Button("改为控制 \(connection.name)") { Task { await relay.start() } }
                    }
                    if relay.state.isActive {
                        HStack {
                            Button((relay.state.reading?.readingMode ?? .paged).previousLabel) { Task { await relay.send(.previous) } }.disabled(relay.busy || relay.state.reading?.canGoPrevious != true)
                            Spacer()
                            Button((relay.state.reading?.readingMode ?? .paged).nextLabel) { Task { await relay.send(.next) } }.disabled(relay.busy || relay.state.reading?.canGoNext != true)
                        }.buttonStyle(.borderless)
                    }
                }
                Section {
                    Button(model.connection == nil ? "连接 iPad 或 Mac" : "选择阅读设备") { showDevices = true }
                    Text("连接 Mac 后，也可以在手机书库中下载图书。已配对的设备无需重复添加。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if relay.enabled {
                        Menu("更多") { Button("暂停自动连接") { relay.stop() } }
                    }
                }
                Section("在 Mac 上阅读") {
                    Text("手表可以直接连接 Mac。在 Mac 打开“手表遥控 → 连接新设备”，再在手表选择这台 Mac。")
                    Text("无需手机中转，也不要求同一 Wi-Fi。").font(.footnote).foregroundStyle(.secondary)
                }
                Section { NavigationLink("操作与连接帮助") { WatchReadingHelp() } }
            }
            .navigationTitle("手表与阅读设备").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented:$showDevices) { devices }
            .task { model.startDiscovery(); await relay.refresh() }
            .onDisappear { model.cancelPairing() }
        }.tint(accent)
    }
    private var devices: some View {
        NavigationStack {
            List {
                if let connection = model.connection {
                    Section("当前遥控设备") {
                        Label(connection.name,systemImage:connection.deviceKind == "ipad" ? "ipad" : "desktopcomputer")
                        Text(model.watchState).font(.footnote).foregroundStyle(.secondary)
                        Text("已配对设备会自动恢复连接，无需重复添加。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let library = try? ConnectionStore.load(), library.receiverID != model.connection?.receiverID {
                    Section("Mac 书库设备") {
                        Button("切换遥控到 \(library.name)") { model.selectSavedMac(library) }
                    }
                }
                if model.isPairing {
                    Section("连接 \(model.selectedName)") {
                        if let code = model.comparisonCode {
                            Text(code).font(.system(.largeTitle,design:.monospaced).weight(.medium)).tracking(5).minimumScaleFactor(0.6)
                            Text("核对阅读设备上的数字，并在阅读设备允许连接。")
                        } else { ProgressView("正在连接…") }
                        Button("取消",role:.cancel) { model.cancelPairing() }
                    }
                } else {
                    Section("附近的阅读设备") {
                        ForEach(model.nearby) { mac in Button { model.pair(mac) } label: { Label(mac.name + (mac.id == model.connection?.receiverID ? " · 已配对" : ""),systemImage:mac.symbol) } }
                        if model.nearby.isEmpty { Text("请在 Mac 或 iPad 开启连接新设备，并允许两端访问本地网络。").foregroundStyle(.secondary) }
                        Button("重新查找") { model.rescan() }
                    }
                }
                Section { Text(model.message).font(.callout).foregroundStyle(.secondary) }
            }.navigationTitle("阅读设备").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { showDevices = false } } }
        }.tint(accent)
    }
}

@main
struct BookSlidePhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { PhoneLibraryView() } }
}
