import Foundation
import Observation

public typealias StreamPlaybackEngineFactory = @MainActor () -> any StreamPlaybackEngine

@MainActor
@Observable
public final class CameraSessionCoordinator {
    public private(set) var sessions: [UUID: CameraSession] = [:]

    public init() {}

    public func session(
        for profile: CameraProfile,
        makeEngine: StreamPlaybackEngineFactory
    ) -> CameraSession {
        if let existing = sessions[profile.id] {
            if existing.profile != profile {
                LumaCamDiagnostics.log(
                    "replacing cached session for edited profile \(profile.diagnosticsSummary)",
                    category: "coordinator",
                    cameraID: profile.id
                )
                existing.disconnect()
                let replacement = CameraSession(profile: profile, engine: makeEngine())
                sessions[profile.id] = replacement
                return replacement
            }
            LumaCamDiagnostics.log(
                "reusing cached session for \(profile.diagnosticsSummary)",
                level: .debug,
                category: "coordinator",
                cameraID: profile.id
            )
            return existing
        }

        LumaCamDiagnostics.log(
            "creating new session for \(profile.diagnosticsSummary)",
            category: "coordinator",
            cameraID: profile.id
        )
        let session = CameraSession(profile: profile, engine: makeEngine())
        sessions[profile.id] = session
        return session
    }

    public func removeSession(for profileID: UUID) {
        LumaCamDiagnostics.log(
            "removing session for camera id=\(profileID.uuidString.lowercased())",
            category: "coordinator",
            cameraID: profileID
        )
        sessions[profileID]?.disconnect()
        sessions[profileID] = nil
    }
}
