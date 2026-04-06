import XCTest
@testable import LumaCamCore

final class LumaCamCoreTests: XCTestCase {
    @MainActor
    func testEndpointBuildsResolvedURL() {
        let endpoint = CameraEndpoint(
            displayName: "Front Door",
            host: "192.168.1.40",
            port: 554,
            path: "stream1",
            username: "viewer",
            preferredTransport: .tcp,
            resolvedPassword: "secret"
        )

        XCTAssertEqual(
            endpoint.resolvedRTSPURL()?.absoluteString,
            "rtsp://viewer:secret@192.168.1.40:554/stream1"
        )
        XCTAssertNil(endpoint.sanitizedForPersistence().resolvedPassword)
        XCTAssertEqual(endpoint.sanitizedForPersistence().persistedCredentialID, endpoint.defaultCredentialID)
    }

    @MainActor
    func testRegistryPersistsAndResolvesPasswords() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let credentials = MemoryCredentialStore()
        let registry = CameraRegistry(
            defaults: defaults,
            defaultsKey: "profiles",
            credentialStore: credentials,
            syncStore: nil
        )

        let profile = CameraProfile(
            endpoint: CameraEndpoint(
                displayName: "Garage",
                host: "cam.local",
                path: "/live",
                username: "admin",
                resolvedPassword: "pw123"
            )
        )

        try registry.upsert(profile)
        let stored = try XCTUnwrap(registry.profile(id: profile.id))
        XCTAssertNil(stored.endpoint.resolvedPassword)

        let resolved = try XCTUnwrap(registry.resolvedProfile(id: profile.id))
        XCTAssertEqual(resolved.endpoint.resolvedPassword, "pw123")
    }

    @MainActor
    func testDuplicatedProfileCopiesSettingsAndIndependentCredentials() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let credentials = MemoryCredentialStore()
        let registry = CameraRegistry(
            defaults: defaults,
            defaultsKey: "profiles",
            credentialStore: credentials,
            syncStore: nil
        )

        let original = CameraProfile(
            endpoint: CameraEndpoint(
                displayName: "Cam A",
                host: "192.168.1.10",
                port: 8554,
                path: "/h264",
                username: "u1",
                preferredTransport: .tcp,
                resolvedPassword: "shared-secret"
            ),
            note: "Roof",
            lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try registry.upsert(original)
        let resolvedOriginal = try XCTUnwrap(registry.resolvedProfile(id: original.id))

        let duplicate = resolvedOriginal.duplicated()
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.displayName, "Cam A Copy")
        XCTAssertEqual(duplicate.endpoint.host, "192.168.1.10")
        XCTAssertEqual(duplicate.endpoint.resolvedPassword, "shared-secret")
        XCTAssertNotEqual(duplicate.endpoint.persistedCredentialID, original.endpoint.persistedCredentialID)

        try registry.upsert(duplicate)
        XCTAssertEqual(registry.profiles.count, 2)
        let resolvedDup = try XCTUnwrap(registry.resolvedProfile(id: duplicate.id))
        XCTAssertEqual(resolvedDup.endpoint.resolvedPassword, "shared-secret")
    }

    @MainActor
    func testSessionReconnectsAfterFailure() async throws {
        let engine = MockPlaybackEngine()
        let session = CameraSession(
            profile: CameraProfile(
                endpoint: CameraEndpoint(displayName: "Office", host: "10.0.0.8", path: "/stream")
            ),
            engine: engine,
            reconnectPolicy: ReconnectPolicy(maxAttempts: 2, baseDelay: .milliseconds(10), maxDelay: .milliseconds(20))
        )

        session.setVisible(true)
        session.connect()
        XCTAssertEqual(session.state, .connecting)

        engine.onStateChange?(.failed(.networkUnavailable))
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertGreaterThanOrEqual(engine.prepareCallCount, 2)
        XCTAssertEqual(session.state, .connecting)
    }

    @MainActor
    func testRegistryMirrorsToICloudStoreAndAdoptsRemoteChanges() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let credentials = MemoryCredentialStore()
        let syncStore = MemoryCameraProfileSyncStore()
        let registry = CameraRegistry(
            defaults: defaults,
            defaultsKey: "profiles",
            credentialStore: credentials,
            syncStore: syncStore
        )

        let localProfile = CameraProfile(
            endpoint: CameraEndpoint(displayName: "Yard", host: "yard.local", path: "/live")
        )
        try registry.upsert(localProfile)
        XCTAssertEqual(syncStore.snapshot?.profiles.map(\.displayName), ["Yard"])

        let remoteProfile = CameraProfile(
            endpoint: CameraEndpoint(displayName: "Porch", host: "porch.local", path: "/stream")
        )
        syncStore.simulateRemoteChange(
            CameraProfileSnapshot(
                profiles: [remoteProfile],
                updatedAt: Date().addingTimeInterval(30)
            )
        )

        // Remote callback is scheduled on MainActor asynchronously (matches real iCloud KVS behavior).
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registry.profiles.map(\.displayName), ["Porch"])
    }

    @MainActor
    func testDashboardRegistryPersistsAndPrunesCameraReferences() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let dashboards = DashboardRegistry(defaults: defaults, defaultsKey: "dashboards")

        let camA = UUID()
        let camB = UUID()
        let dash = CameraDashboard(name: "Home Wall", cameraIDs: [camA, camB])
        try dashboards.upsert(dash)

        let reloaded = DashboardRegistry(defaults: defaults, defaultsKey: "dashboards")
        XCTAssertEqual(reloaded.dashboards.count, 1)
        XCTAssertEqual(reloaded.dashboards[0].cameraIDs, [camA, camB])

        try dashboards.removeCameraIDFromAllDashboards(camA)
        XCTAssertEqual(dashboards.dashboards[0].cameraIDs, [camB])
    }
}

private final class MemoryCredentialStore: @unchecked Sendable, CredentialStore {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func savePassword(_ password: String, for credentialID: String) throws {
        lock.lock()
        storage[credentialID] = password
        lock.unlock()
    }

    func password(for credentialID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[credentialID]
    }

    func deletePassword(for credentialID: String) throws {
        lock.lock()
        storage[credentialID] = nil
        lock.unlock()
    }
}

private final class MemoryCameraProfileSyncStore: CameraProfileSyncStore {
    var onChange: ((CameraProfileSnapshot) -> Void)?
    var snapshot: CameraProfileSnapshot?

    func loadSnapshot() -> CameraProfileSnapshot? {
        snapshot
    }

    func saveSnapshot(_ snapshot: CameraProfileSnapshot) {
        self.snapshot = snapshot
    }

    func synchronize() {}

    func simulateRemoteChange(_ snapshot: CameraProfileSnapshot) {
        self.snapshot = snapshot
        onChange?(snapshot)
    }
}

@MainActor
private final class MockPlaybackEngine: StreamPlaybackEngine {
    var onStateChange: ((StreamPlaybackState) -> Void)?
    var onStatisticsChange: ((PlaybackStatistics?) -> Void)?
    private(set) var prepareCallCount = 0

    func prepare(endpoint: CameraEndpoint) throws {
        prepareCallCount += 1
    }

    func start() {}

    func stop() {
        onStateChange?(.stopped)
    }

    func setVisible(_ isVisible: Bool) {}
}
