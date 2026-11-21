import Foundation
import CryptoKit

public enum RequestAuthentication {
    private static func key(_ token: String) -> SymmetricKey { SymmetricKey(data: Data(token.utf8)) }
    private static func canonical(method: String, path: String, time: String, nonce: String, body: Data) -> Data {
        Data("BookSlide/v2\n\(method)\n\(path)\n\(time)\n\(nonce)\n\(Data(SHA256.hash(data: body)).base64EncodedString())".utf8)
    }

    public static func headers(method: String, path: String, body: Data = Data(), token: String,
                               now: Date = Date(), nonce: String = UUID().uuidString) -> [String: String] {
        let time = String(Int64(now.timeIntervalSince1970))
        let code = HMAC<SHA256>.authenticationCode(for: canonical(method: method, path: path, time: time, nonce: nonce, body: body), using: key(token))
        return ["x-bookslide-time": time, "x-bookslide-nonce": nonce,
                "x-bookslide-signature": Data(code).base64EncodedString()]
    }

    public static func verify(_ request: HTTPRequest, token: String, now: Date = Date()) -> Bool {
        guard !token.isEmpty, let time = request.headers["x-bookslide-time"], let seconds = Double(time),
              seconds.isFinite, abs(now.timeIntervalSince1970 - seconds) <= 10,
              let nonce = request.headers["x-bookslide-nonce"], UUID(uuidString: nonce) != nil,
              let signature = request.headers["x-bookslide-signature"], let bytes = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: canonical(method: request.method, path: request.path, time: time, nonce: nonce, body: request.body), using: key(token))
    }

    private static func responseBytes(status: Int, nonce: String, body: Data) -> Data {
        Data("BookSlide/response/v2\n\(status)\n\(nonce)\n".utf8) + body
    }

    public static func sign(_ response: HTTPResponse, for request: HTTPRequest, token: String) -> HTTPResponse {
        var result = response
        let bytes = responseBytes(status: response.status, nonce: request.headers["x-bookslide-nonce"] ?? "", body: response.body)
        result.extraHeaders["X-BookSlide-Signature"] = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key(token))).base64EncodedString()
        return result
    }

    public static func verifyResponse(status: Int, body: Data, signature: String?, nonce: String, token: String) -> Bool {
        guard let signature, let code = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: responseBytes(status: status, nonce: nonce, body: body), using: key(token))
    }
}
