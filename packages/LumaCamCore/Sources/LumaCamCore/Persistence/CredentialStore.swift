import Foundation

public protocol CredentialStore: Sendable {
    func savePassword(_ password: String, for credentialID: String) throws
    func password(for credentialID: String) throws -> String?
    func deletePassword(for credentialID: String) throws
}
