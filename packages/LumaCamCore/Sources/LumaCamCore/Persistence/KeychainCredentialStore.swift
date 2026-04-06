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
        if let password = try passwordUsingBaseQuery(
            baseQuery(for: credentialID, matchAnySynchronizable: true, restrictToAccessGroup: true)
        ) {
            return password
        }
        // iOS uses an explicit access group (Watch sharing); macOS historically used the default
        // container. Profiles sync via iCloud KVS while keychain items may be stored or synced
        // without the access-group attribute, so a second lookup without `kSecAttrAccessGroup`
        // finds those credentials.
        if accessGroup != nil {
            return try passwordUsingBaseQuery(
                baseQuery(for: credentialID, matchAnySynchronizable: true, restrictToAccessGroup: false)
            )
        }
        return nil
    }

    public func deletePassword(for credentialID: String) throws {
        let restrictVariants: [Bool] = accessGroup != nil ? [true, false] : [true]
        var anySuccess = false
        var fatal: OSStatus?

        for restrict in restrictVariants {
            let status = SecItemDelete(
                baseQuery(for: credentialID, matchAnySynchronizable: true, restrictToAccessGroup: restrict) as CFDictionary
            )
            if status == errSecSuccess {
                anySuccess = true
            } else if status != errSecItemNotFound {
                fatal = status
            }
        }

        if !anySuccess, let fatal {
            throw StoreError.unexpectedStatus(fatal)
        }
    }

    private func passwordUsingBaseQuery(_ base: [String: Any]) throws -> String? {
        var query = base
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

    private func baseQuery(for credentialID: String, matchAnySynchronizable: Bool, restrictToAccessGroup: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
        ]

        if restrictToAccessGroup, let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        query[kSecAttrSynchronizable as String] = matchAnySynchronizable ? kSecAttrSynchronizableAny : synchronizable
        return query
    }
}
