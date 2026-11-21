import Foundation

/// The same authenticated reader protocol, carried over BLE rather than TCP.
public enum BluetoothWire {
    public static let service = "7AA84C01-57A9-4E78-92F5-50424F4F4B53"
    public static let input = "7AA84C02-57A9-4E78-92F5-50424F4F4B53"
    public static let output = "7AA84C03-57A9-4E78-92F5-50424F4F4B53"
    public static let maximumSize = 16_384
    public static func allows(_ request: HTTPRequest) -> Bool {
        (request.method == "GET" && request.path == "/v3/status") ||
        (request.method == "POST" && ["/v3/turn", "/v2/pair/start", "/v2/pair/poll"].contains(request.path))
    }
    public static func frame(_ data: Data, mtu: Int) throws -> [Data] {
        guard !data.isEmpty, data.count <= maximumSize, mtu > 4 else { throw Failure.invalidFrame }
        let size = UInt32(data.count)
        var framed = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        framed.append(data)
        return stride(from: 0, to: framed.count, by: mtu).map { Data(framed[$0..<min($0 + mtu, framed.count)]) }
    }
    public enum Failure: Error { case invalidFrame }
}

public struct BluetoothFrameDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> Data? {
        guard !data.isEmpty, buffer.count + data.count <= BluetoothWire.maximumSize + 4 else {
            buffer.removeAll(); throw BluetoothWire.Failure.invalidFrame
        }
        buffer.append(data)
        guard buffer.count >= 4 else { return nil }
        let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= BluetoothWire.maximumSize, buffer.count <= size + 4 else {
            buffer.removeAll(); throw BluetoothWire.Failure.invalidFrame
        }
        guard buffer.count == size + 4 else { return nil }
        defer { buffer.removeAll() }
        return Data(buffer.dropFirst(4))
    }
}

public struct BluetoothRequest: Codable {
    public let id: UUID
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public init(_ request: HTTPRequest, id: UUID = UUID()) {
        self.id = id; method = request.method; path = request.path; headers = request.headers; body = request.body
    }
    public var request: HTTPRequest { HTTPRequest(method: method, path: path, headers: headers, body: body) }
}

public struct BluetoothResponse: Codable {
    public let id: UUID
    public let status: Int
    public let signature: String?
    public let body: Data
    public init(id: UUID, response: HTTPResponse) {
        self.id = id; status = response.status; signature = response.extraHeaders["X-BookSlide-Signature"]
        body = response.body
    }
}
