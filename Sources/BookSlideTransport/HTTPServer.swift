import Foundation
import Network
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// All state and handlers run on the main queue, including Books foreground checks.
public final class HTTPServer {
    public var onState: ((String, UInt16?) -> Void)?
    private var listener: NWListener?
    private var advertisement: NetService?
    private var clients: [UUID: Client] = [:]
    private let handler: (HTTPRequest) async -> HTTPResponse

    public init(handler: @escaping (HTTPRequest) async -> HTTPResponse) { self.handler = handler }

    public func start(port: UInt16 = 8765, loopbackOnly: Bool = false, serviceName: String? = nil, receiverID: UUID? = nil, deviceKind: String = "mac") throws {
        stop()
        let parameters = NWParameters.tcp
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                if let serviceName, let receiverID, let port = listener.port?.rawValue {
                    let service = NetService(domain: "local.", type: "_bookslide._tcp.", name: serviceName, port: Int32(port))
                    service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(receiverID.uuidString.utf8), "version": Data("2".utf8), "kind": Data(deviceKind.utf8)]))
                    self.advertisement = service
                    service.publish()
                }
                self.onState?("正在接收", listener.port?.rawValue)
            case .failed(let error):
                self.stop()
                self.onState?("启动失败：\(error.localizedDescription)", nil)
            case .waiting(let error): self.onState?("等待网络：\(error.localizedDescription)", nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.clients.count < 16 else { connection.cancel(); return }
            let id = UUID()
            let client = Client(connection: connection, handler: self.handler) { [weak self] in self?.clients[id] = nil }
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: .main)
    }

    public func stop() {
        advertisement?.stop(); advertisement = nil
        listener?.cancel(); listener = nil
        let pending = Array(clients.values)
        clients.removeAll()
        pending.forEach { $0.close() }
    }
}

private final class Client {
    private let connection: NWConnection
    private let handler: (HTTPRequest) async -> HTTPResponse
    private let onClose: () -> Void
    private var parser = HTTPParser()
    private var deadline: DispatchWorkItem?
    private var closed = false

    init(connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse, onClose: @escaping () -> Void) {
        self.connection = connection; self.handler = handler; self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        connection.start(queue: .main)
        let deadline = DispatchWorkItem { [weak self] in self?.close() }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, let request = try self.parser.append(data) {
                    Task { @MainActor in
                        let response = await self.handler(request)
                        if !self.closed { self.send(response) }
                    }; return
                }
                if complete || error != nil { self.close() } else { self.receive() }
            } catch HTTPParser.Failure.tooLarge {
                self.send(HTTPResponse(413, Reply(ok: false, message: "请求过大")))
            } catch {
                self.send(HTTPResponse(400, Reply(ok: false, message: "HTTP 请求格式不正确")))
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel(); deadline = nil
        connection.cancel()
        onClose()
    }
}
