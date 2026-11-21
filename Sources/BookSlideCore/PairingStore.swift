import Foundation
import Security

public enum PairingStore {
    public enum Failure: Error { case keychain(OSStatus), random(OSStatus) }
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "BookSlide") + ".pairing",
         kSecAttrAccount as String: account]
    }

    public static func load(account: String = "mac-receiver") throws -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw Failure.keychain(status) }
        return value
    }

    public static func save(_ value: String, account: String = "mac-receiver") throws {
        let query = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        } else if updated != errSecSuccess { throw Failure.keychain(updated) }
    }

    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.random(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
