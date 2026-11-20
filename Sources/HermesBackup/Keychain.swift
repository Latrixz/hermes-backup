import Foundation
import Security

/// The backup password lives in the login Keychain, never in a file.
enum Keychain {
    private static let service = "com.quantumape.hermesbackup"
    private static let account = "backup-password"

    /// Whether a password is saved, WITHOUT reading it: asking for the attributes only never
    /// shows the "wants to use your confidential information" prompt; reading the secret can.
    static var hasPassword: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true]
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    static func password() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Hermes Backup password"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
