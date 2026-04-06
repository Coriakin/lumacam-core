import Foundation
import Observation

@MainActor
@Observable
public final class DashboardRegistry {
    public private(set) var dashboards: [CameraDashboard]

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "LumaCam.savedDashboards"
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.dashboards = Self.load(from: defaults, key: defaultsKey, decoder: decoder)
    }

    public func upsert(_ dashboard: CameraDashboard) throws {
        let persisted = dashboard.sanitizedForPersistence()
        if let index = dashboards.firstIndex(where: { $0.id == persisted.id }) {
            dashboards[index] = persisted
        } else {
            dashboards.append(persisted)
        }
        dashboards.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try persist()
    }

    public func delete(_ dashboardID: UUID) throws {
        dashboards.removeAll { $0.id == dashboardID }
        try persist()
    }

    public func dashboard(id: UUID) -> CameraDashboard? {
        dashboards.first { $0.id == id }
    }

    /// Removes a camera from every dashboard (e.g. after the camera is deleted).
    public func removeCameraIDFromAllDashboards(_ cameraID: UUID) throws {
        var changed = false
        dashboards = dashboards.map { dash in
            let filtered = dash.cameraIDs.filter { $0 != cameraID }
            if filtered.count != dash.cameraIDs.count {
                changed = true
                var copy = dash
                copy.cameraIDs = filtered
                return copy
            }
            return dash
        }
        if changed {
            try persist()
        }
    }

    private func persist() throws {
        let data = try encoder.encode(dashboards)
        defaults.set(data, forKey: defaultsKey)
    }

    private static func load(from defaults: UserDefaults, key: String, decoder: JSONDecoder) -> [CameraDashboard] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return (try? decoder.decode([CameraDashboard].self, from: data)) ?? []
    }
}
