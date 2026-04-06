import Foundation

public struct CameraProfileSnapshot: Equatable, Sendable {
    public var profiles: [CameraProfile]
    public var updatedAt: Date

    public init(profiles: [CameraProfile], updatedAt: Date) {
        self.profiles = profiles
        self.updatedAt = updatedAt
    }
}

/// Not MainActor-isolated: iCloud KVS notifications arrive on arbitrary queues.
public protocol CameraProfileSyncStore: AnyObject {
    var onChange: ((CameraProfileSnapshot) -> Void)? { get set }

    func loadSnapshot() -> CameraProfileSnapshot?
    func saveSnapshot(_ snapshot: CameraProfileSnapshot)
    func synchronize()
}
