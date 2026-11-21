import Foundation
import Combine
import CoreBluetooth
import CryptoKit

/// Apple Watch is the central; Mac or iPad advertises the reader service.
/// All callbacks, framing, and request completion run on the main queue.
final class DirectWatchLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = DirectWatchLink()
    struct Device: Identifiable {
        let id: UUID; let name: String; var kind: String = "mac"
        var symbol: String { kind == "ipad" ? "ipad" : "desktopcomputer" }
    }
    @Published private(set) var devices: [Device] = []
    @Published private(set) var rememberedDevices: [Device] = []
    @Published private(set) var discoveryMessage = "正在查找附近的设备…"
    @Published private(set) var pairingError: String?
    private(set) var routeID = UUID()
    private var discoveryTimeout: DispatchWorkItem?
    private var lastDiagnosticAt = -Double.infinity
    @Published private(set) var message = "未连接阅读设备"
    @Published private(set) var comparisonCode: String?
    @Published private(set) var pairing = false
    @Published private(set) var connected = false
    @Published private(set) var authenticated = false
    var onContext: ((PhoneControlState) -> Void)?
    var onState: ((String) -> Void)?
    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private var enabled = false
    private var browsing = false
    @Published private(set) var selectedDeviceID: UUID?
    private var connection: SavedConnection?
    private let pairingStore = BluetoothPairingStore()
    @Published private(set) var rememberedDeviceName: String?
    private var state = PhoneControlState(message: "请在手表连接阅读设备")
    private var decoder = BluetoothFrameDecoder()
    private var chunks: [Data] = []
    private var writeInFlight = false
    private var receivedResponse: BluetoothResponse?
    private struct Pending {
        let id: UUID
        let expiresAt: Double?
        var completion: ((Result<BluetoothResponse, Error>) -> Void)?
    }
    private var pending: Pending?
    private var lifecycle = BluetoothExchangeLifecycle()
    private var timeoutWork: DispatchWorkItem?
    private var setupTimeoutWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var retryDelay = 1.0
    private var foreground = true
    private var resetting = false
    private var needsStatusRefresh = true
    private var requestInProgress = false
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    var hasPairedDevice: Bool { rememberedDeviceName != nil }
    var isSynchronizing: Bool { pending != nil || requestInProgress }
    private var pairTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    private override init() {
        super.init()
        selectedDeviceID = pairingStore.rememberedPeripheralID
        rememberedDeviceName = pairingStore.rememberedName
        rememberedDevices = pairingStore.rememberedDevices.map { Device(id: $0.peripheralID, name: $0.connection.name, kind: $0.connection.deviceKind ?? "mac") }
        restorePairing()
    }
    private func restorePairing() {
        guard connection == nil else { return }
        do {
            if let record = try pairingStore.load() {
                selectedDeviceID = record.peripheralID; connection = record.connection
                rememberedDeviceName = record.connection.name
                refreshRememberedDevices()
                status("正在连接 \(record.connection.name)…", suspend: true)
            }
        } catch {
            // A locked/unavailable Keychain is not an unpaired watch. Retry on
            // activation and periodic refresh, preserving the remembered reader.
            status("暂时无法读取配对，请解锁手表后重试", suspend: true)
        }
    }
    private func refreshRememberedDevices() {
        if let records = try? pairingStore.loadAll() {
            rememberedDevices = records.map { Device(id: $0.peripheralID, name: $0.connection.name, kind: $0.connection.deviceKind ?? "mac") }
        }
    }
    func select(_ id: UUID) {
        guard !pairing else { return }
        pairingError = nil
        do {
            if let record = try pairingStore.loadAll().first(where: { $0.peripheralID == id }) {
                if id == selectedDeviceID, connected, authenticated {
                    needsStatusRefresh = true; refreshWhenReady(); return
                }
                let saved = try pairingStore.select(record.peripheralID)
                routeID = UUID()
                reconnectWork?.cancel(); reconnectWork = nil
                disconnect("正在连接 \(saved.connection.name)…")
                selectedDeviceID = saved.peripheralID; connection = saved.connection
                rememberedDeviceName = saved.connection.name
                state = PhoneControlState(message: "正在连接 \(saved.connection.name)…")
                onContext?(state)
                activate(); scan()
                return
            }
            pair(with: id)
        } catch { pairingError = "暂时无法读取已保存的设备，请解锁手表后重试" }
    }
    func activate() {
        enabled = true
        restorePairing()
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
        else { reconnect() }
    }
    func deactivate() {
        reconnectWork?.cancel(); reconnectWork = nil
        enabled = false; browsing = false; manager?.stopScan(); pairTask?.cancel(); pairTask = nil
        disconnect("已切换连接方式")
    }
    func setForeground(_ active: Bool) {
        foreground = active
        defer { writeDiagnostics(force: true) }
        lifecycle.setActive(active, now: now)
        timeoutWork?.cancel(); setupTimeoutWork?.cancel()
        if active {
            activate(); scheduleTimeout(); scheduleSetupTimeout()
            if !resetting { refreshWhenReady() }
        } else {
            stopBrowsing()
            if !pairing, lifecycle.abandonCaller() {
                needsStatusRefresh = true
                finishCaller(.failure(Failure(text: "操作确认已暂停，唤醒后会刷新书页")))
            }
        }
    }
    private func trace(_ event: String, error: Error? = nil) {
        if let error { let e = error as NSError; NSLog("BookSlide BLE %@ error=%@/%ld", event, e.domain, e.code) }
        else { NSLog("BookSlide BLE %@", event) }
    }
    func browse() {
        guard !pairing, !browsing else { return }
        browsing = true; devices = []
        discoveryMessage = "正在查找附近的设备…"
        activate(); scan()
        discoveryTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.browsing, self.manager?.state == .poweredOn else { return }
            self.discoveryMessage = self.devices.isEmpty ? "未发现新设备，请在 iPad 或 Mac 打开书籍人生" : "点选要阅读的设备"
        }
        discoveryTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    func searchAgain() { stopBrowsing(); browse() }
    func retryConnection() {
        guard !pairing else { return }
        if hasPairedDevice { activate(); rebuildConnection("正在重新连接…") }
        else { browse() }
    }
    func stopBrowsing() {
        browsing = false; discoveryTimeout?.cancel(); discoveryTimeout = nil
        manager?.stopScan(); writeDiagnostics(force: true)
    }
    private func status(_ text: String, suspend: Bool = false) {
        message = text; onState?(text)
        writeDiagnostics()
        if suspend { state = state.suspended(text); onContext?(state) }
    }
    private func writeDiagnostics(force: Bool = false) {
        #if DEBUG
        guard force || now - lastDiagnosticAt >= 1 else { return }
        lastDiagnosticAt = now
        let diagnostic: [String: Any] = ["updatedAt": Date().timeIntervalSince1970,
            "message": message, "enabled": enabled, "browsing": browsing, "foreground": foreground,
            "managerState": manager?.state.rawValue ?? -1,
            "authorization": CBManager.authorization.rawValue,
            "discoveredCount": devices.count, "discoveredNames": devices.map(\.name),
            "rememberedCount": rememberedDevices.count, "connected": connected, "authenticated": authenticated]
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("BookSlideBluetoothDiagnostics.json"), options: .atomic)
        }
        #endif
    }
    private func scan() {
        guard enabled, foreground, let manager else { return }
        guard manager.state == .poweredOn else {
            if manager.state == .unauthorized { discoveryMessage = "请在手表设置允许书籍人生使用蓝牙" }
            else if manager.state == .poweredOff { discoveryMessage = "请打开手表蓝牙" }
            else if manager.state == .unsupported { discoveryMessage = "当前设备不支持附近连接" }
            return
        }
        manager.scanForPeripherals(withServices: [CBUUID(string: BluetoothWire.service)])
        writeDiagnostics(force: true)
    }
    private func reconnect() {
        guard enabled, !pairing, manager?.state == .poweredOn, peripheral == nil else { return }
        reconnectWork?.cancel(); reconnectWork = nil
        if let selectedDeviceID, connection != nil,
           let known = manager.retrievePeripherals(withIdentifiers: [selectedDeviceID]).first {
            connect(known)
        } else {
            // Leave the last pairing error visible until the user retries.
            if browsing || connection != nil { scan() }
        }
    }
    private func connect(_ target: CBPeripheral) {
        peripheral = target; target.delegate = self
        resetting = false; connectionGeneration = UUID()
        trace("connect requested")
        status("正在蓝牙连接 \(target.name ?? "阅读设备")…", suspend: true)
        manager.connect(target)
        // Core Bluetooth keeps this request pending while the reader is asleep or
        // out of range. Cancelling it every eight seconds prevented recovery.
    }
    private func clearTransport(_ text: String) {
        setupTimeoutWork?.cancel(); setupTimeoutWork = nil
        input = nil; output = nil; connected = false; authenticated = false; needsStatusRefresh = true
        connectionGeneration = UUID(); chunks.removeAll(); writeInFlight = false
        finish(.failure(Failure(text: text)))
        status(text, suspend: true)
    }
    private func disconnect(_ text: String) {
        let old = peripheral
        peripheral = nil; resetting = false
        clearTransport(text)
        if let old, manager?.state == .poweredOn { manager?.cancelPeripheralConnection(old) }
    }
    /// Used only for corrupt/stalled transport, not a single slow reply.
    private func rebuildConnection(_ text: String) {
        guard !resetting else { return }
        trace("rebuild stalled/invalid transport")
        let old = peripheral
        resetting = true; clearTransport(text)
        if let old, old.state != .disconnected, manager.state == .poweredOn {
            // Keep the identity until didDisconnect so the reconnect is issued
            // from Core Bluetooth's callback, including when running in background.
            manager.cancelPeripheralConnection(old)
        } else {
            peripheral = nil; resetting = false; reconnect()
        }
    }
    private func scheduleSetupTimeout() {
        setupTimeoutWork?.cancel()
        guard foreground, peripheral?.state == .connected, !connected, !resetting else { return }
        let generation = connectionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.foreground, !self.connected, self.connectionGeneration == generation else { return }
            self.rebuildConnection("阅读设备服务发现未完成，正在重新连接")
        }
        setupTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }
    private func scheduleReconnect() {
        guard enabled, !pairing, manager.state == .poweredOn else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconnect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(30, retryDelay * 2)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard enabled else { return }
        if central.state == .poweredOn { reconnect(); if browsing { scan() } }
        else {
            let text: String
            switch central.state {
            case .unauthorized: text = "请在手表设置允许书籍人生使用蓝牙"
            case .poweredOff: text = "请打开手表蓝牙"
            case .unsupported: text = "当前设备不支持附近连接"
            default: text = "正在准备连接…"
            }
            discoveryMessage = text; disconnect(text)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        if !devices.contains(where: { $0.id == peripheral.identifier }) {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "阅读设备"
            devices.append(Device(id: peripheral.identifier, name: name, kind: name.hasPrefix("iPad") ? "ipad" : "mac"))
        }
        if browsing, !pairing { discoveryMessage = "点选要阅读的设备" }
        writeDiagnostics(force: true)
        if enabled, !pairing, self.peripheral == nil, peripheral.identifier == selectedDeviceID, connection != nil { connect(peripheral) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, !resetting else { return }
        trace("connected"); scheduleSetupTimeout()
        peripheral.discoverServices([CBUUID(string: BluetoothWire.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        trace("connect failed", error: error)
        self.peripheral = nil; resetting = false
        clearTransport("阅读设备暂不可达，正在自动重连")
        scheduleReconnect()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        trace("disconnected", error: error)
        self.peripheral = nil; resetting = false
        clearTransport("与阅读设备的蓝牙连接已断开，正在自动重连")
        reconnect()
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard self.peripheral === peripheral,
              invalidatedServices.contains(where: { $0.uuid == CBUUID(string: BluetoothWire.service) }) else { return }
        rebuildConnection("阅读设备阅读服务已重启，正在恢复连接")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, !resetting else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BluetoothWire.service) }) else {
            rebuildConnection("未找到阅读设备阅读服务，正在重连"); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: BluetoothWire.input), CBUUID(string: BluetoothWire.output)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, !resetting else { return }
        input = service.characteristics?.first { $0.uuid == CBUUID(string: BluetoothWire.input) }
        output = service.characteristics?.first { $0.uuid == CBUUID(string: BluetoothWire.output) }
        guard error == nil, input != nil, let output else { rebuildConnection("阅读设备蓝牙服务不完整，正在重连"); return }
        peripheral.setNotifyValue(true, for: output)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, !resetting, characteristic.uuid == CBUUID(string: BluetoothWire.output) else { return }
        guard error == nil, characteristic.isNotifying else { rebuildConnection("无法订阅阅读设备翻页状态，正在重连"); return }
        setupTimeoutWork?.cancel(); setupTimeoutWork = nil
        connected = true; retryDelay = 1; trace("reader service ready")
        if !browsing { manager.stopScan() }
        status("蓝牙已连接 · 正在验证阅读设备")
        refreshWhenReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, !resetting else { return }
        guard error == nil else { trace("write failed", error: error); rebuildConnection("发送失败，正在恢复连接；请确认书页"); return }
        writeInFlight = false
        if let response = receivedResponse, chunks.isEmpty { finish(.success(response)) }
        else { writeNext() }
    }
    private func writeNext() {
        guard pending != nil, !writeInFlight, let peripheral, let input, !chunks.isEmpty else { return }
        if let expiry = pending?.expiresAt, Date().timeIntervalSince1970 >= expiry {
            rebuildConnection("操作已过期，已丢弃未发送的滚动；正在刷新连接"); return
        }
        writeInFlight = true
        peripheral.writeValue(chunks.removeFirst(), for: input, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, !resetting, characteristic.uuid == CBUUID(string: BluetoothWire.output), pending != nil else { return }
        guard error == nil, let data = characteristic.value else { rebuildConnection("蓝牙接收失败，正在重连；请确认书页"); return }
        do {
            guard let bytes = try decoder.append(data) else { return }
            let response = try JSONDecoder().decode(BluetoothResponse.self, from: bytes)
            guard response.id == pending?.id else {
                trace("ignored late response from previous request"); return
            }
            if writeInFlight { receivedResponse = response } else { finish(.success(response)) }
        } catch { rebuildConnection("阅读设备回复损坏，正在恢复连接") }
    }
    private func finishCaller(_ result: Result<BluetoothResponse, Error>) {
        let completion = pending?.completion; pending?.completion = nil
        completion?(result)
    }
    private func finish(_ result: Result<BluetoothResponse, Error>) {
        let abandoned = pending != nil && pending?.completion == nil
        let completion = pending?.completion
        if let id = pending?.id { lifecycle.complete(id: id) }
        pending = nil; timeoutWork?.cancel(); timeoutWork = nil
        chunks.removeAll(); decoder = BluetoothFrameDecoder(); receivedResponse = nil
        completion?(result)
        if abandoned { trace("late exchange drained without replay"); refreshWhenReady() }
    }
    private func scheduleTimeout() {
        timeoutWork?.cancel()
        guard let id = pending?.id, let delay = lifecycle.nextTimeout(after: now) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            switch self.lifecycle.timeout(now: self.now) {
            case .replyDelayed:
                self.trace("reply delayed; keeping BLE connection")
                self.needsStatusRefresh = true
                self.status("阅读设备回复较慢，蓝牙仍连接；正在等待确认", suspend: true)
                self.finishCaller(.failure(Failure(text: "操作尚未确认，请查看阅读设备书页；蓝牙连接保留")))
                self.scheduleTimeout()
            case .transportStalled:
                self.rebuildConnection("传输持续未响应，正在自动恢复；不补发翻页")
            case nil: self.scheduleTimeout()
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }
    private func refreshWhenReady() {
        guard enabled, foreground, connected, !resetting, !pairing, needsStatusRefresh,
              pending == nil, !requestInProgress, connection != nil else { return }
        // Only refresh status after recovery. Never retain or retry a turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.foreground, !self.resetting, self.needsStatusRefresh,
                  !self.isSynchronizing, self.connected, !self.pairing else { return }
            self.request(nil) { _ in }
        }
    }
    private func exchange(_ request: HTTPRequest) async throws -> BluetoothResponse {
        guard pending == nil else { throw Failure(text: "正在等待上一条操作的确认，请稍候") }
        guard foreground, connected, !resetting, let peripheral, input != nil else { throw Failure(text: "正在恢复阅读设备蓝牙连接") }
        let packet = BluetoothRequest(request)
        let frames = try BluetoothWire.frame(JSONEncoder().encode(packet), mtu: peripheral.maximumWriteValueLength(for: .withResponse))
        let command = request.path == "/v3/turn" ? try JSONDecoder().decode(TurnCommand.self, from: request.body) : nil
        return try await withCheckedThrowingContinuation { continuation in
            guard lifecycle.begin(id: packet.id, now: now, active: foreground) else {
                continuation.resume(throwing: Failure(text: "正在同步阅读设备状态")); return
            }
            pending = Pending(id: packet.id, expiresAt: command.map { $0.sentAt + 5 }, completion: { continuation.resume(with: $0) })
            chunks = frames; writeNext(); scheduleTimeout()
        }
    }
    @MainActor func waitForActivation() async {
        activate()
        for _ in 0..<20 {
            if connected || Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    func request(_ command: WatchTurnRequest?, completion: @escaping (Reply) -> Void) {
        activate()
        guard !pairing else { completion(Reply(ok: false, message: "请先核对配对数字")); return }
        guard let connection else {
            completion(Reply(ok: false, message: hasPairedDevice ? message : "请选择要阅读的设备")); return
        }
        guard connected, selectedDeviceID == peripheral?.identifier else {
            completion(Reply(ok: false, message: message)); return
        }
        guard command == nil || state.accepts(command!) else {
            completion(Reply(ok: false, message: "阅读状态已改变，请刷新后再操作")); return
        }
        // A periodic refresh must not overtake an in-flight turn.
        guard !isSynchronizing else { completion(Reply(ok: false, message: "正在等待阅读设备确认，请稍候")); return }
        requestInProgress = true
        let generation = connectionGeneration
        Task { @MainActor in
            defer { requestInProgress = false }
            do {
                guard generation == connectionGeneration else { throw Failure(text: "连接已改变，请重新操作") }
                let path = command == nil ? "/v3/status" : "/v3/turn"
                let body = try command.map { try JSONEncoder().encode($0.command) } ?? Data()
                let method = command == nil ? "GET" : "POST"
                var headers = RequestAuthentication.headers(method: method, path: path, body: body, token: connection.token)
                headers["content-type"] = "application/json"
                let response = try await exchange(HTTPRequest(method: method, path: path, headers: headers, body: body))
                guard generation == connectionGeneration, RequestAuthentication.verifyResponse(status: response.status, body: response.body,
                    signature: response.signature, nonce: headers["x-bookslide-nonce"]!, token: connection.token) else {
                    throw Failure(text: "无法验证阅读设备，请重新配对")
                }
                let reply = try JSONDecoder().decode(Reply.self, from: response.body)
                guard !reply.ok || reply.commandID == command?.command.id else { throw Failure(text: "翻页确认不匹配") }
                authenticated = true
                needsStatusRefresh = false
                state = state.following(receiverID: connection.receiverID, name: connection.name, reading: reply.reading)
                if !reply.ok { state = state.suspended(reply.message) }
                state.message = reply.ok ? (reply.reading == nil ? "已连接，请在\(connection.name)打开一本书" : "已连接 \(connection.name)") : reply.message
                onContext?(state); status(state.message); completion(reply)
            } catch {
                if generation == connectionGeneration { needsStatusRefresh = true; status(error.localizedDescription, suspend: true) }
                completion(Reply(ok: false, message: error.localizedDescription))
            }
        }
    }
    func repair(_ id: UUID) {
        guard peripherals[id] != nil else {
            pairingError = "请在这台设备打开“手表遥控”，等待它出现在附近后再试"; return
        }
        pair(with: id)
    }
    private func pair(with id: UUID) {
        restorePairing()
        guard !pairing, let target = peripherals[id] else { return }
        routeID = UUID(); pairingError = nil
        reconnectWork?.cancel(); reconnectWork = nil
        stopBrowsing()
        pairing = true; comparisonCode = nil
        if peripheral !== target {
            disconnect("正在连接所选阅读设备…"); connect(target)
        }
        pairTask = Task { @MainActor in
            defer {
                pairing = false; comparisonCode = nil; pairTask = nil
                if foreground, !state.isActive { browse() }
            }
            do {
                var remaining = 300
                while remaining > 0 {
                    try Task.checkCancellation()
                    if connected { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if foreground { remaining -= 1 }
                }
                guard connected, peripheral === target else { throw Failure(text: "阅读设备未连接，请重新选择") }
                let key = Curve25519.KeyAgreement.PrivateKey(), helloID = UUID()
                let hello = PairingHello(id: helloID, clientName: "Apple Watch", publicKey: key.publicKey.rawRepresentation)
                let response = try await pairingExchange(HTTPRequest(method: "POST", path: "/v2/pair/start", headers: [:], body: JSONEncoder().encode(hello)))
                let reply = try JSONDecoder().decode(Reply.self, from: response.body)
                guard reply.ok, let challenge = reply.pairing, challenge.id == helloID else { throw Failure(text: reply.message) }
                let secret = try PairingCrypto.key(privateKey: key, remote: challenge.publicKey, clientPublic: hello.publicKey,
                                                  serverPublic: challenge.publicKey, id: helloID, receiverID: challenge.receiverID)
                comparisonCode = PairingCrypto.comparisonCode(secret)
                status("核对两端数字，在阅读设备允许连接")
                for _ in 0..<115 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Task.checkCancellation()
                    guard peripheral === target else { throw Failure(text: "配对连接已断开") }
                    let poll = try await pairingExchange(HTTPRequest(method: "POST", path: "/v2/pair/poll", headers: [:], body: JSONEncoder().encode(PairingPoll(id: helloID))))
                    let result = try JSONDecoder().decode(Reply.self, from: poll.body)
                    if let envelope = result.encryptedConnection {
                        let saved = try PairingCrypto.open(envelope, key: secret, id: helloID)
                        guard saved.isValid, saved.receiverID == challenge.receiverID else { throw Failure(text: "配对信息无效") }
                        try pairingStore.save(.init(peripheralID: id, connection: saved))
                        selectedDeviceID = id; connection = saved; pairing = false; browsing = false; manager.stopScan()
                        rememberedDeviceName = saved.name
                        refreshRememberedDevices()
                        status("已记住 \(saved.name)")
                        if foreground { request(nil) { _ in } }; return
                    }
                    guard poll.status == 202 else { throw Failure(text: result.message) }
                }
                throw Failure(text: "确认已超时，请在阅读设备打开“手表遥控”后再选一次")
            } catch {
                if !(error is CancellationError) { pairingError = error.localizedDescription }
                if peripheral === target { disconnect(error is CancellationError ? "已取消连接" : error.localizedDescription) }
            }
        }
    }
    private func pairingExchange(_ request: HTTPRequest) async throws -> BluetoothResponse {
        // Looking at the reader to approve must not cancel the watch handshake.
        while !foreground {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        return try await exchange(request)
    }
    func cancelPairing() { pairTask?.cancel() }
}
