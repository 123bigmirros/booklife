import Foundation
import CryptoKit

public struct SavedConnection: Codable, Equatable {
    public let receiverID: UUID
    public let name: String
    public var endpoint: String
    public let token: String
    public let deviceKind: String?

    public init(receiverID: UUID, name: String, endpoint: String, token: String, deviceKind: String? = nil) {
        self.receiverID = receiverID; self.name = name; self.endpoint = endpoint; self.token = token
        self.deviceKind = deviceKind
    }

    public static func localURL(_ text: String) -> URL? {
        guard let c = URLComponents(string: text), c.scheme == "http", let host = c.host,
              let port = c.port, (1...65535).contains(port), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        let ipv4 = parts.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } &&
            (octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
             (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 169 && octets[1] == 254))
        guard ipv4 || (host.lowercased().hasSuffix(".local") && host.count > 6) else { return nil }
        return c.url
    }
    public var isValid: Bool {
        Self.localURL(endpoint) != nil && !name.isEmpty && name.count <= 100 &&
        token.count == 32 && token.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

public struct PairingHello: Codable, Equatable {
    public let id: UUID
    public let clientName: String
    public let publicKey: Data
    public init(id: UUID, clientName: String, publicKey: Data) {
        self.id = id; self.clientName = clientName; self.publicKey = publicKey
    }
}
public struct PairingChallenge: Codable, Equatable {
    public let id: UUID
    public let receiverID: UUID
    public let publicKey: Data
}
public struct PairingPoll: Codable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public enum PairingCrypto {
    public static func key(privateKey: Curve25519.KeyAgreement.PrivateKey, remote: Data,
                           clientPublic: Data, serverPublic: Data, id: UUID, receiverID: UUID) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: clientPublic + serverPublic,
            sharedInfo: Data("BookSlide/pair/v2/\(id.uuidString)/\(receiverID.uuidString)".utf8), outputByteCount: 32)
    }
    public static func comparisonCode(_ key: SymmetricKey) -> String {
        let bytes = Array(HMAC<SHA256>.authenticationCode(for: Data("compare-on-both-screens".utf8), using: key))
        let n = bytes.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000
        return String(format: "%06llu", n)
    }
    public static func seal(_ connection: SavedConnection, key: SymmetricKey, id: UUID) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(connection), using: key, authenticating: Data(id.uuidString.utf8)).combined!
    }
    public static func open(_ data: Data, key: SymmetricKey, id: UUID) throws -> SavedConnection {
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(id.uuidString.utf8))
        return try JSONDecoder().decode(SavedConnection.self, from: plaintext)
    }
}

/// Explicit 2-minute enrollment window, one candidate at a time, approval on the receiving device.
/// Shared secrets never appear in Bonjour records or unencrypted pairing responses.
public final class PairingCoordinator {
    public struct Pending {
        public let id: UUID
        public let clientName: String
        public let code: String
    }
    public var onChange: (() -> Void)?
    public private(set) var pending: Pending?
    public private(set) var isOpen = false
    private let receiverID: UUID
    private let credentials: () -> SavedConnection?
    private var deadline = Date.distantPast
    private var hello: PairingHello?
    private var challenge: PairingChallenge?
    private var secret: SymmetricKey?
    private var envelope: Data?

    public init(receiverID: UUID, credentials: @escaping () -> SavedConnection?) {
        self.receiverID = receiverID; self.credentials = credentials
    }
    public func begin(now: Date = Date()) {
        clear(); isOpen = true; deadline = now.addingTimeInterval(120); onChange?()
    }
    public func clear() {
        isOpen = false; pending = nil; hello = nil; challenge = nil; secret = nil; envelope = nil
        deadline = .distantPast; onChange?()
    }
    public func expire(now: Date = Date()) {
        if (isOpen || challenge != nil), now >= deadline { clear() }
    }
    @discardableResult
    public func approve(id: UUID, now: Date = Date()) -> Bool {
        expire(now: now)
        guard isOpen, pending?.id == id, let secret, let connection = credentials(), connection.isValid,
              let encrypted = try? PairingCrypto.seal(connection, key: secret, id: id) else { return false }
        envelope = encrypted; pending = nil; isOpen = false
        deadline = now.addingTimeInterval(30); onChange?()
        return true
    }
    public func handle(_ request: HTTPRequest, now: Date = Date()) -> HTTPResponse? {
        guard request.path.hasPrefix("/v2/pair/") else { return nil }
        expire(now: now)
        func response(_ status: Int, _ text: String) -> HTTPResponse { HTTPResponse(status, Reply(ok: false, message: text)) }
        guard request.method == "POST" else { return response(400, "无效的连接请求") }
        if request.path == "/v2/pair/start" {
            guard isOpen else { return response(409, "请先在这台设备打开“手表遥控”，再点一次设备名称") }
            guard let input = try? JSONDecoder().decode(PairingHello.self, from: request.body),
                  (1...60).contains(input.clientName.count), input.publicKey.count == 32 else { return response(400, "连接请求不完整") }
            if let hello, hello != input { return response(409, "阅读设备正在确认另一台设备，请稍后重试") }
            if challenge == nil {
                do {
                    let privateKey = Curve25519.KeyAgreement.PrivateKey()
                    let publicKey = privateKey.publicKey.rawRepresentation
                    let key = try PairingCrypto.key(privateKey: privateKey, remote: input.publicKey,
                        clientPublic: input.publicKey, serverPublic: publicKey, id: input.id, receiverID: receiverID)
                    hello = input; secret = key
                    challenge = PairingChallenge(id: input.id, receiverID: receiverID, publicKey: publicKey)
                    pending = Pending(id: input.id, clientName: input.clientName, code: PairingCrypto.comparisonCode(key))
                    onChange?()
                } catch { return response(400, "无法验证设备") }
            }
            var reply = Reply(ok: true, message: "请核对两端数字，并在阅读设备确认")
            reply.pairing = challenge
            return HTTPResponse(200, reply)
        }
        if request.path == "/v2/pair/poll" {
            guard let poll = try? JSONDecoder().decode(PairingPoll.self, from: request.body),
                  poll.id == challenge?.id else { return response(410, "配对已结束，请重新连接") }
            if let envelope {
                var reply = Reply(ok: true, message: "配对完成")
                reply.encryptedConnection = envelope
                return HTTPResponse(200, reply)
            }
            return response(202, "等待阅读设备确认")
        }
        return response(404, "不支持的连接请求")
    }
}
