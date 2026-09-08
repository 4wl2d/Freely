import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func load() async throws -> String?
    func save(_ credential: String) async throws
    func delete() async throws
}

public enum CredentialStoreError: Error, Sendable, LocalizedError {
    case invalidCredential
    case keychain(status: Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter a nonempty API key without whitespace."
        case .keychain(let status): "Keychain access failed (status \(status)). Unlock your login Keychain and try again."
        }
    }
}

/// Serializes access and keeps key contents out of descriptions, files and UserDefaults.
public actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String
    public init(service: String = "com.freely.xai-api", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func load() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
        guard let data = result as? Data, let credential = String(data: data, encoding: .utf8), !credential.isEmpty else {
            throw CredentialStoreError.invalidCredential
        }
        return credential
    }

    public func save(_ credential: String) throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw CredentialStoreError.invalidCredential
        }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status: status) }
    }
}
