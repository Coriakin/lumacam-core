import Foundation
import Observation

@MainActor
@Observable
public final class CameraRegistry {
    public private(set) var profiles: [CameraProfile]

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let defaultsTimestampKey: String
    private let credentialStore: CredentialStore
    private let syncStore: (any CameraProfileSyncStore)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "LumaCam.savedProfiles",
        credentialStore: CredentialStore = KeychainCredentialStore(),
        syncStore: (any CameraProfileSyncStore)? = UbiquitousCameraProfileSyncStore()
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.defaultsTimestampKey = defaultsKey + ".updatedAt"
        self.credentialStore = credentialStore
        self.syncStore = syncStore
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.profiles = []
        let snapshot = resolvedInitialSnapshot()
        self.profiles = snapshot?.profiles ?? []
        if let snapshot {
            persist(snapshot: snapshot, mirrorToSyncStore: false)
        }
        self.syncStore?.onChange = { [weak self] snapshot in
            // iCloud KVS notifications are delivered off the main queue; registry is MainActor-isolated.
            Task { @MainActor [weak self] in
                self?.applyRemoteSnapshotIfNewer(snapshot)
            }
        }
        self.syncStore?.synchronize()
    }

    public func profile(id: UUID) -> CameraProfile? {
        profiles.first { $0.id == id }
    }

    public func resolvedProfile(id: UUID) throws -> CameraProfile? {
        guard let profile = profile(id: id) else {
            return nil
        }

        return try resolve(profile: profile)
    }

    public func upsert(_ profile: CameraProfile) throws {
        let persisted = profile.sanitizedForPersistence()
        if let credentialID = persisted.endpoint.persistedCredentialID {
            if let password = profile.endpoint.resolvedPassword, !password.isEmpty {
                try credentialStore.savePassword(password, for: credentialID)
            } else {
                try credentialStore.deletePassword(for: credentialID)
            }
        }

        if let index = profiles.firstIndex(where: { $0.id == persisted.id }) {
            profiles[index] = persisted
        } else {
            profiles.append(persisted)
        }

        profiles.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try persistProfiles()
    }

    public func delete(_ profileID: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }

        let profile = profiles.remove(at: index)
        if let credentialID = profile.endpoint.persistedCredentialID {
            try credentialStore.deletePassword(for: credentialID)
        }
        try persistProfiles()
    }

    public func markConnected(_ profileID: UUID, at date: Date = .now) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }

        profiles[index] = profiles[index].markingLastConnected(date)
        try persistProfiles()
    }

    public func resolve(profile: CameraProfile) throws -> CameraProfile {
        var resolved = profile
        if let credentialID = profile.endpoint.persistedCredentialID {
            resolved.endpoint.credentialID = credentialID
            resolved.endpoint.resolvedPassword = try credentialStore.password(for: credentialID)
        }
        return resolved
    }

    private func loadProfiles() -> [CameraProfile] {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return []
        }

        do {
            return try decoder.decode([CameraProfile].self, from: data)
        } catch {
            return []
        }
    }

    private func persistProfiles() throws {
        persist(
            snapshot: CameraProfileSnapshot(profiles: profiles, updatedAt: .now),
            mirrorToSyncStore: true
        )
    }

    private func resolvedInitialSnapshot() -> CameraProfileSnapshot? {
        let local = localSnapshot()
        let remote = syncStore?.loadSnapshot()

        switch (local, remote) {
        case let (local?, remote?):
            if remote.updatedAt > local.updatedAt {
                return remote
            }
            if local.updatedAt > remote.updatedAt {
                syncStore?.saveSnapshot(local)
            }
            return local
        case let (local?, nil):
            syncStore?.saveSnapshot(local)
            return local
        case let (nil, remote?):
            return remote
        case (nil, nil):
            return nil
        }
    }

    private func localSnapshot() -> CameraProfileSnapshot? {
        let profiles = loadProfiles()
        guard !profiles.isEmpty || defaults.object(forKey: defaultsTimestampKey) != nil else {
            return nil
        }

        return CameraProfileSnapshot(
            profiles: profiles,
            updatedAt: defaults.object(forKey: defaultsTimestampKey) as? Date ?? .distantPast
        )
    }

    private func applyRemoteSnapshotIfNewer(_ snapshot: CameraProfileSnapshot) {
        if let current = localSnapshot(), snapshot.updatedAt <= current.updatedAt {
            return
        }

        deleteOrphanedCredentials(from: profiles, comparedTo: snapshot.profiles)
        profiles = sortedProfiles(snapshot.profiles)
        persist(
            snapshot: CameraProfileSnapshot(profiles: profiles, updatedAt: snapshot.updatedAt),
            mirrorToSyncStore: false
        )
    }

    private func persist(snapshot: CameraProfileSnapshot, mirrorToSyncStore: Bool) {
        guard let data = try? encoder.encode(snapshot.profiles) else {
            return
        }

        defaults.set(data, forKey: defaultsKey)
        defaults.set(snapshot.updatedAt, forKey: defaultsTimestampKey)
        if mirrorToSyncStore {
            syncStore?.saveSnapshot(snapshot)
        }
    }

    private func deleteOrphanedCredentials(from oldProfiles: [CameraProfile], comparedTo newProfiles: [CameraProfile]) {
        let remainingCredentialIDs = Set(newProfiles.compactMap(\.endpoint.persistedCredentialID))
        let removedCredentialIDs = Set(oldProfiles.compactMap(\.endpoint.persistedCredentialID))
            .subtracting(remainingCredentialIDs)

        for credentialID in removedCredentialIDs {
            try? credentialStore.deletePassword(for: credentialID)
        }
    }

    private func sortedProfiles(_ profiles: [CameraProfile]) -> [CameraProfile] {
        profiles.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
