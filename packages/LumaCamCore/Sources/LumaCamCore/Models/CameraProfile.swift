import Foundation

public struct CameraProfile: Identifiable, Codable, Equatable, Sendable {
    public var endpoint: CameraEndpoint
    public var note: String
    public var lastConnectedAt: Date?

    public init(
        endpoint: CameraEndpoint,
        note: String = "",
        lastConnectedAt: Date? = nil
    ) {
        self.endpoint = endpoint
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastConnectedAt = lastConnectedAt
    }

    public var id: UUID {
        endpoint.id
    }

    public var displayName: String {
        endpoint.displayName
    }

    public func sanitizedForPersistence() -> CameraProfile {
        CameraProfile(
            endpoint: endpoint.sanitizedForPersistence(),
            note: note,
            lastConnectedAt: lastConnectedAt
        )
    }

    public func markingLastConnected(_ date: Date = .now) -> CameraProfile {
        var copy = self
        copy.lastConnectedAt = date
        return copy
    }

    /// New profile with a fresh endpoint id and keychain slot; copies RTSP fields, note, and resolved password for upsert.
    public func duplicated(displayNameSuffix: String = "Copy") -> CameraProfile {
        var newEndpoint = endpoint
        newEndpoint.id = UUID()
        newEndpoint.credentialID = nil
        let suffix = displayNameSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty {
            newEndpoint.displayName = endpoint.displayName + " " + suffix
        }
        return CameraProfile(
            endpoint: newEndpoint,
            note: note,
            lastConnectedAt: nil
        )
    }
}
