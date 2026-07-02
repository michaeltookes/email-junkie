import Foundation
import os
import Security

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Keychain")

/// Errors thrown by `KeychainStore`.
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

/// A `SecretStore` backed by the macOS Keychain (generic-password items).
///
/// Items are scoped by a `service` identifier and marked accessible after first
/// unlock, this-device-only (never synced to iCloud). This uses the default
/// keychain and the generic-password class, so it needs no special entitlement.
final class KeychainStore: SecretStore {

    static let shared = KeychainStore()

    private let service: String

    init(service: String = "com.tookes.EmailJunkie") {
        self.service = service
    }

    func set(_ value: String, for key: SecretKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }

        // Delete any existing item first so the write is idempotent.
        SecItemDelete(baseQuery(for: key) as CFDictionary)

        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Keychain set failed for \(key.rawValue, privacy: .public): \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func value(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain read failed for \(key.rawValue, privacy: .public): \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func remove(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // On macOS, SecItemDelete removes a single matching item per call, so
        // loop until nothing is left.
        var status = SecItemDelete(query as CFDictionary)
        while status == errSecSuccess {
            status = SecItemDelete(query as CFDictionary)
        }
        guard status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
