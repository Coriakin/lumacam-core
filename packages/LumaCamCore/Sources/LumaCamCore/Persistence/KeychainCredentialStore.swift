import Foundation
import Security

public struct KeychainCredentialStore: CredentialStore {
    public enum StoreError: Error {
        case unexpectedStatus(OSStatus)
        case invalidData
    }

    private let service: String
    private let accessGroup: String?
    private let synchronizable: Bool

    public init(
        service: String = "se.andreasbjorn.LumaCam.credentials",
        accessGroup: String? = nil,
        synchronizable: Bool = true
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    public func savePassword(_ password: String, for credentialID: String) throws {
        let encoded = Data(password.utf8)
        let query = baseQuery(for: credentialID, matchAnySynchronizable: true)
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess {
            return
        }

        if status != errSecItemNotFound {
            throw StoreError.unexpectedStatus(status)
        }

        var addQuery = baseQuery(for: credentialID, matchAnySynchronizable: false)
        addQuery[kSecValueData as String] = encoded
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = synchronizable
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.unexpectedStatus(addStatus)
        }
    }

    public func password(for credentialID: String) throws -> String? {
        var query = baseQuery(for: credentialID, matchAnySynchronizable: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw StoreError.unexpectedStatus(status)
        }

        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidData
        }

        return password
    }

    public func deletePassword(for credentialID: String) throws {
        let status = SecItemDelete(baseQuery(for: credentialID, matchAnySynchronizable: true) as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw StoreError.unexpectedStatus(status)
    }

    private func baseQuery(for credentialID: String, matchAnySynchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        query[kSecAttrSynchronizable as String] = matchAnySynchronizable ? kSecAttrSynchronizableAny : synchronizable
        return query
    }
}
