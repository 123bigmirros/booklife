#if os(macOS) || os(iOS)
import Foundation
import CoreBluetooth
#if os(macOS)
import AppKit
#endif
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Main-queue BLE peripheral. No phone, IP discovery, or network forwarding.
public final class BluetoothReceiver: NSObject, CBPeripheralManagerDelegate {
    public var onState: ((String) -> Void)?
    public var onAvailability: ((Bool) -> Void)?
    public private(set) var isReady = false { didSet { onAvailability?(isReady) } }
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var manager: CBPeripheralManager!
    private var output: CBMutableCharacteristic?
    private var active = false
    private var serviceReady = false
    private var publishing = false
    private var recoveryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var name = "书籍人生"
    private struct Peer {
        var decoder = BluetoothFrameDecoder()
        var busy = false
        var generation = UUID()
    }
    private var peers: [UUID: Peer] = [:]
    private var outgoing: [(CBCentral, Data)] = []
    public init(handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
        super.init()
    }
    public func start(name: String) {
        self.name = name; active = true
        if recoveryTimer == nil {
            recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.recoverAdvertising() }
            #if os(macOS)
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.recoverAdvertising()
            }
            #endif
        }
        if manager == nil { manager = CBPeripheralManager(delegate: self, queue: .main) }
        else if manager.state == .poweredOn, output == nil { publish() }
        report("正在准备蓝牙…")
    }
    private func report(_ message: String) {
        onState?(message)
        #if DEBUG && os(iOS)
        // Local development diagnostics only; never include credentials or book content.
        let state: [String: Any] = ["updatedAt": Date().timeIntervalSince1970,
            "message": message, "active": active, "ready": isReady,
            "managerState": manager?.state.rawValue ?? -1,
            "authorization": CBManager.authorization.rawValue]
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("BookSlideBluetoothDiagnostics.json"), options: .atomic)
        }
        #endif
    }
    public func stop() {
        active = false; isReady = false; manager?.stopAdvertising(); manager?.removeAllServices()
        recoveryTimer?.invalidate(); recoveryTimer = nil
        #if os(macOS)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }; wakeObserver = nil
        #endif
        serviceReady = false; publishing = false
        output = nil; peers.removeAll(); outgoing.removeAll(); report("蓝牙直连已暂停")
    }
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        isReady = false; output = nil; serviceReady = false; publishing = false; peers.removeAll(); outgoing.removeAll()
        guard active else { return }
        switch peripheral.state {
        case .poweredOn: publish()
        case .poweredOff: report("请打开阅读设备蓝牙")
        case .unauthorized: report("请在系统设置允许书籍人生使用蓝牙")
        case .unsupported: report("此设备不支持蓝牙直连")
        default: report("正在准备蓝牙…")
        }
    }
    private func recoverAdvertising() {
        guard active, manager?.state == .poweredOn, !publishing else { return }
        if !serviceReady { publish() }
        else if !manager.isAdvertising { advertise() }
    }
    private func advertise() {
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BluetoothWire.service)], CBAdvertisementDataLocalNameKey: name])
    }
    private func publish() {
        guard !publishing else { return }
        publishing = true; serviceReady = false
        manager.removeAllServices()
        let input = CBMutableCharacteristic(type: CBUUID(string: BluetoothWire.input), properties: [.write], value: nil, permissions: [.writeable])
        let output = CBMutableCharacteristic(type: CBUUID(string: BluetoothWire.output), properties: [.notify], value: nil, permissions: [])
        self.output = output
        let service = CBMutableService(type: CBUUID(string: BluetoothWire.service), primary: true)
        service.characteristics = [input, output]; manager.add(service)
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard active else { return }
        publishing = false
        guard error == nil else { output = nil; report("蓝牙服务暂不可用，正在自动恢复"); return }
        serviceReady = true; advertise()
    }
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard active else { return }
        isReady = error == nil
        report(error == nil ? "蓝牙直连已开启 · 等待手表" : "蓝牙广播暂不可用，正在自动恢复")
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard active, peers[central.identifier] != nil || peers.count < 8 else { return }
        outgoing.removeAll { $0.0.identifier == central.identifier }
        peers[central.identifier] = Peer()
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        peers.removeValue(forKey: central.identifier)
        outgoing.removeAll { $0.0.identifier == central.identifier }
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // The watch sends one with-response fragment at a time.
        guard requests.count == 1, let request = requests.first else {
            if let first = requests.first { peripheral.respond(to: first, withResult: .requestNotSupported) }; return
        }
        let id = request.central.identifier
        guard active, request.characteristic.uuid == CBUUID(string: BluetoothWire.input), request.offset == 0,
              let data = request.value, var peer = peers[id], !peer.busy,
              !outgoing.contains(where: { $0.0.identifier == id }) else {
            peripheral.respond(to: request, withResult: .unlikelyError); return
        }
        do {
            let complete = try peer.decoder.append(data)
            peers[id] = peer
            guard let complete else { peripheral.respond(to: request, withResult: .success); return }
            let packet = try JSONDecoder().decode(BluetoothRequest.self, from: complete)
            guard BluetoothWire.allows(packet.request) else { throw BluetoothWire.Failure.invalidFrame }
            peer.busy = true; peers[id] = peer
            peripheral.respond(to: request, withResult: .success)
            let generation = peer.generation
            Task { @MainActor in
                let response = await handler(packet.request)
                guard active, peers[id]?.generation == generation else { return }
                peers[id]?.busy = false
                guard let bytes = try? JSONEncoder().encode(BluetoothResponse(id: packet.id, response: response)),
                      let chunks = try? BluetoothWire.frame(bytes, mtu: request.central.maximumUpdateValueLength) else { return }
                outgoing += chunks.map { (request.central, $0) }
                flush()
            }
        } catch {
            peers[id]?.decoder = BluetoothFrameDecoder()
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
        }
    }
    private func flush() {
        outgoing.removeAll { peers[$0.0.identifier] == nil }
        guard let output else { return }
        while let first = outgoing.first {
            guard manager.updateValue(first.1, for: output, onSubscribedCentrals: [first.0]) else { return }
            outgoing.removeFirst()
        }
    }
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
}
#endif
