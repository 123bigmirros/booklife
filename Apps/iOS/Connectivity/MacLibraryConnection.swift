import SwiftUI
import Foundation
import CryptoKit
import UIKit

/// Library transfer only; never changes the Watch or remote-control target.
final class MacLibraryConnection: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = MacLibraryConnection()
    @Published var nearby: [NearbyReader] = []
    @Published var connection: SavedConnection?
    @Published var message = "正在查找附近的 Mac…"
    @Published var comparisonCode: String?
    @Published var selectedName = ""
    @Published var isPairing = false
    @Published var testing = false
    @Published var catalogRevision = 0
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var resolved: [String: NearbyReader] = [:]
    private let session = ReceiverClient.librarySession()
    private var pairingTask: Task<Void, Never>?
    private var browsing = false
    private var refreshing: Set<UUID> = []

    override init() {
        super.init()
        connection = try? ConnectionStore.load()
        browser.delegate = self
    }
    func startDiscovery() {
        connection = try? ConnectionStore.load()
        guard !browsing else { return }
        browsing = true; message = "正在查找附近的 Mac…"
        browser.searchForServices(ofType: "_bookslide._tcp.", inDomain: "local.")
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
        guard kind == "mac" else { return }
        let mac = NearbyReader(id: id, name: service.name, endpoint: endpoint, deviceKind: kind)
        resolved[key(service)] = mac; updateNearby()
        refreshSavedEndpoint(mac)
    }
    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        message = "发现了设备，但尚未连接成功；请刷新重试。"
    }
    private func updateNearby() {
        nearby = Dictionary(resolved.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name < $1.name }
        if !isPairing { message = nearby.isEmpty ? "请在 Mac 打开书籍人生。" : "选择要同步图书的 Mac。" }
    }
    private func refreshSavedEndpoint(_ mac: NearbyReader) {
        guard let old = connection, old.receiverID == mac.id, !refreshing.contains(mac.id) else { return }
        refreshing.insert(mac.id)
        Task { @MainActor in
            defer { self.refreshing.remove(mac.id) }
            var updated = old; updated.endpoint = mac.endpoint
            do {
                // Authenticate the discovery result before replacing the saved address.
                let reply = try await ReceiverClient.library(connection: updated, session: session)
                guard reply.ok else { return }
                guard self.connection?.receiverID == old.receiverID, self.connection?.token == old.token else { return }
                try ConnectionStore.save(updated)
                self.connection = updated
                self.catalogRevision += 1

            } catch { /* Do not replace a trusted address with an unverified advertisement. */ }
        }
    }
    func pair(_ mac: NearbyReader) {
        guard !isPairing else { return }
        if let connection, connection.receiverID == mac.id { selectSavedMac(connection); return }
        isPairing = true; selectedName = mac.name; comparisonCode = nil
        message = "正在连接 Mac 书库…"
        pairingTask = Task { @MainActor in
            defer { self.isPairing = false; self.comparisonCode = nil }
            do {
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let hello = PairingHello(id: UUID(), clientName: UIDevice.current.userInterfaceIdiom == .pad ? "我的 iPad" : "我的 iPhone", publicKey: privateKey.publicKey.rawRepresentation)
                let initialResponse = try await pairingRequest(mac, path: "start", body: JSONEncoder().encode(hello))
                let initial = initialResponse.reply
                try Task.checkCancellation()
                guard initialResponse.status == 200, initial.ok, let challenge = initial.pairing, challenge.id == hello.id, challenge.receiverID == mac.id else {
                    message = initialResponse.status == 409 ? "请在 Mac 打开“手表遥控 → 连接新设备”，然后再点这台 Mac。" : initial.message
                    return
                }
                let key = try PairingCrypto.key(privateKey: privateKey, remote: challenge.publicKey,
                    clientPublic: hello.publicKey, serverPublic: challenge.publicKey, id: hello.id, receiverID: mac.id)
                comparisonCode = PairingCrypto.comparisonCode(key)
                message = "确认 Mac 显示相同数字，然后在 Mac 点击允许连接。"
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let response = try await pairingRequest(mac, path: "poll", body: JSONEncoder().encode(PairingPoll(id: hello.id)))
                    let reply = response.reply
                    try Task.checkCancellation()
                    if response.status == 200, reply.ok, let envelope = reply.encryptedConnection {
                        var saved = try PairingCrypto.open(envelope, key: key, id: hello.id)
                        guard saved.receiverID == mac.id, saved.isValid else { throw ReceiverClient.Failure.invalidResponse }
                        // Use the successfully resolved Bonjour hostname, not a changing IPv4 address.
                        saved.endpoint = mac.endpoint
                        let library = try await ReceiverClient.library(connection: saved, session: session)
                        guard library.ok else { throw ReceiverClient.Failure.invalidResponse }
                        try Task.checkCancellation()
                        try ConnectionStore.save(saved)
                        connection = saved
                        message = "已连接 \(saved.name)，正在更新书库…"
                        return
                    }
                    if response.status != 202 { message = reply.message; return }
                }
                message = "等待确认已超时，请重新连接"
            } catch is CancellationError { message = "已取消连接" }
            catch { message = "连接未完成：\(error.localizedDescription)" }
        }
    }
    private func pairingRequest(_ mac: NearbyReader, path: String, body: Data) async throws -> (status: Int, reply: Reply) {
        guard let base = SavedConnection.localURL(mac.endpoint) else { throw ReceiverClient.Failure.invalidAddress }
        var request = URLRequest(url: base.appendingPathComponent("v2/pair/" + path))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReceiverClient.Failure.invalidResponse }
        return (http.statusCode, try JSONDecoder().decode(Reply.self, from: data))
    }
    func cancelPairing() { pairingTask?.cancel(); pairingTask = nil }
    func selectSavedMac(_ saved: SavedConnection) {
        do {
            try ConnectionStore.save(saved); connection = saved
        } catch { message = "无法切换设备：\(error.localizedDescription)" }
    }
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

struct MacLibrarySetup: View {
    @ObservedObject private var model = MacLibraryConnection.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let connection = model.connection, !model.isPairing {
                    Section("已连接的书库") {
                        Label(connection.name, systemImage: "desktopcomputer")
                        Text("返回书库即可看到图书，点封面下载阅读。").foregroundStyle(.secondary)
                        Button("查看图书") { dismiss() }
                    }
                }
                if model.isPairing {
                    Section("连接 \(model.selectedName)") {
                        if let code = model.comparisonCode {
                            Text(code).font(.system(.largeTitle, design: .monospaced)).tracking(5)
                            Text("确认 Mac 上显示相同数字，并在 Mac 允许连接。")
                        } else { ProgressView("正在连接书库…") }
                        Button("取消", role: .cancel) { model.cancelPairing() }
                    }
                } else {
                    Section("附近的 Mac") {
                        ForEach(model.nearby) { mac in
                            Button { model.pair(mac) } label: {
                                Label(mac.name + (mac.id == model.connection?.receiverID ? " · 已连接" : ""), systemImage: "desktopcomputer")
                            }
                        }
                        if model.nearby.isEmpty { Text("在 Mac 打开书籍人生，并让两台设备连接同一 Wi-Fi。").foregroundStyle(.secondary) }
                        Button("重新查找") { model.rescan() }
                    }
                }
                Section {
                    Text(model.message).foregroundStyle(.secondary)
                    Text("首次连接时，在 Mac 打开“手表遥控 → 连接新设备”并核对数字。下载新书时需要 Mac 在线；下载完成后可以独立阅读。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mac 书库").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { model.startDiscovery() }
            .onChange(of: model.connection?.receiverID) { _, value in if value != nil { dismiss() } }
            .onDisappear { model.cancelPairing() }
        }.tint(readingAccent)
    }
}

