import Foundation
import Security

/// Guarda el token / app password de Bitbucket para el iPad en el llavero (no en `workspace.json`).
public enum BitbucketPadCredentialStore: Sendable {
    private static let service = "com.efby.requestlab.bitbucket.pad.apiToken"
    private static let account = "primary"

    public enum Failure: Error, Sendable {
        case keychainFailed(OSStatus)
    }

    public static func saveAPITokenIfPresent(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearAPIToken()
            return
        }
        let data = Data(trimmed.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure.keychainFailed(status)
        }
    }

    public static func loadAPIToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    public static func clearAPIToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
