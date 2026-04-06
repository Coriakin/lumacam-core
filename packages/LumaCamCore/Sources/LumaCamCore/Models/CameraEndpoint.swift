import Foundation

public struct CameraEndpoint: Identifiable, Codable, Equatable, Sendable {
    /// Minimum auto-refresh interval for HTTP snapshots (Apple Watch and similar).
    public static let snapshotRefreshIntervalMinSeconds = 10
    /// Maximum auto-refresh interval for HTTP snapshots.
    public static let snapshotRefreshIntervalMaxSeconds = 600

    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int?
    public var path: String
    public var username: String?
    public var credentialID: String?
    public var preferredTransport: RTSPTransport
    public var resolvedPassword: String?
    /// Full HTTP(S) URL for a still image (snapshot), used by the Watch app. Independent of RTSP host/port when needed.
    public var snapshotURL: URL?
    /// When non-`nil`, the Watch app auto-refreshes the snapshot on this interval (seconds) while the detail view is visible.
    public var snapshotRefreshIntervalSeconds: Int?

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int? = 554,
        path: String,
        username: String? = nil,
        credentialID: String? = nil,
        preferredTransport: RTSPTransport = .automatic,
        resolvedPassword: String? = nil,
        snapshotURL: URL? = nil,
        snapshotRefreshIntervalSeconds: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.path = CameraEndpoint.normalizePath(path)
        self.username = CameraEndpoint.normalizeOptional(username)
        self.credentialID = CameraEndpoint.normalizeOptional(credentialID)
        self.preferredTransport = preferredTransport
        self.resolvedPassword = CameraEndpoint.normalizeOptional(resolvedPassword)
        self.snapshotURL = snapshotURL
        self.snapshotRefreshIntervalSeconds = snapshotRefreshIntervalSeconds
    }

    /// Returns `snapshotRefreshIntervalSeconds` clamped to ``snapshotRefreshIntervalMinSeconds``…``snapshotRefreshIntervalMaxSeconds``, or `nil` if unset.
    public func clampedSnapshotRefreshIntervalSeconds() -> Int? {
        guard let raw = snapshotRefreshIntervalSeconds else { return nil }
        return min(max(raw, Self.snapshotRefreshIntervalMinSeconds), Self.snapshotRefreshIntervalMaxSeconds)
    }

    public static func normalizePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "/"
        }

        if trimmed.hasPrefix("/") {
            return trimmed
        }

        return "/" + trimmed
    }

    public static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var defaultCredentialID: String {
        "camera.\(id.uuidString)"
    }

    public var persistedCredentialID: String? {
        guard username != nil else { return nil }
        return credentialID ?? defaultCredentialID
    }

    public func resolvedRTSPURL() -> URL? {
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = host
        components.port = port
        components.path = Self.normalizePath(path)

        if let username {
            components.user = username
            components.password = resolvedPassword
        }

        return components.url
    }

    public func sanitizedForPersistence() -> CameraEndpoint {
        var copy = self
        copy.credentialID = persistedCredentialID
        copy.resolvedPassword = nil
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case host
        case port
        case path
        case username
        case credentialID
        case preferredTransport
        case snapshotURL
        case snapshotRefreshIntervalSeconds
    }
}
