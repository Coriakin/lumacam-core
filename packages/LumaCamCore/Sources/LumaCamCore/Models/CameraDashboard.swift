import Foundation

public struct CameraDashboard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var cameraIDs: [UUID]

    public init(id: UUID = UUID(), name: String, cameraIDs: [UUID]) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cameraIDs = cameraIDs
    }

    public func sanitizedForPersistence() -> CameraDashboard {
        var seen = Set<UUID>()
        let uniqueOrdered = cameraIDs.filter { seen.insert($0).inserted }
        return CameraDashboard(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            cameraIDs: uniqueOrdered
        )
    }
}
