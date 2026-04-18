import Foundation

public struct CameraProfile: Identifiable, Codable, Equatable, Sendable {
    public var endpoint: CameraEndpoint
    public var note: String
    public var lastConnectedAt: Date?
    public var ptz: PTZConfiguration

    enum CodingKeys: String, CodingKey {
        case endpoint
        case note
        case lastConnectedAt
        case ptz
    }

    public init(
        endpoint: CameraEndpoint,
        note: String = "",
        lastConnectedAt: Date? = nil,
        ptz: PTZConfiguration = .disabled
    ) {
        self.endpoint = endpoint
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastConnectedAt = lastConnectedAt
        self.ptz = ptz
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(CameraEndpoint.self, forKey: .endpoint)
        note = try container.decode(String.self, forKey: .note)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        ptz = try container.decodeIfPresent(PTZConfiguration.self, forKey: .ptz) ?? .disabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        try container.encode(ptz, forKey: .ptz)
    }

    public var id: UUID {
        endpoint.id
    }

    public var displayName: String {
        endpoint.displayName
    }

    /// Whether the Live viewer should show PTZ controls for this profile.
    public var showsLivePTZOverlay: Bool {
        switch ptz.backend {
        case .disabled:
            return false
        case .httpCGI:
            return ptz.http.isUsableForContinuousMove
        case .onvif:
            let user = endpoint.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !user.isEmpty
        }
    }

    public func sanitizedForPersistence() -> CameraProfile {
        CameraProfile(
            endpoint: endpoint.sanitizedForPersistence(),
            note: note,
            lastConnectedAt: lastConnectedAt,
            ptz: ptz
        )
    }

    public func markingLastConnected(_ date: Date = .now) -> CameraProfile {
        var copy = self
        copy.lastConnectedAt = date
        return copy
    }

    /// New profile with a fresh endpoint id and keychain slot; copies RTSP fields, note, PTZ, and resolved password for upsert.
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
            lastConnectedAt: nil,
            ptz: ptz
        )
    }
}
