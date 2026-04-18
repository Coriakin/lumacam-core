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
        XCTAssertEqual(
            endpoint.redactedRTSPURLString,
            "rtsp://viewer@192.168.1.40:554/stream1"
        )
        XCTAssertNil(endpoint.sanitizedForPersistence().resolvedPassword)
        XCTAssertEqual(endpoint.sanitizedForPersistence().persistedCredentialID, endpoint.defaultCredentialID)
    }

    @MainActor
    func testEndpointSplitsIPv4HostWithEmbeddedPort() {
        let endpoint = CameraEndpoint(
            displayName: "Tapo",
            host: "192.168.1.202:554",
            port: 554,
            path: "/stream1",
            username: "viewer",
            preferredTransport: .tcp,
            resolvedPassword: "x"
        )
        XCTAssertEqual(endpoint.host, "192.168.1.202")
        XCTAssertEqual(endpoint.port, 554)
        XCTAssertNotNil(endpoint.resolvedRTSPURL())
        XCTAssertEqual(
            endpoint.redactedRTSPURLString,
            "rtsp://viewer@192.168.1.202:554/stream1"
        )
    }

    @MainActor
    func testEndpointEmbeddedPortOverridesSeparatePortField() {
        let endpoint = CameraEndpoint(
            displayName: "NVR",
            host: "cam.example:8554",
            port: 554,
            path: "/live",
            username: "u",
            resolvedPassword: "p"
        )
        XCTAssertEqual(endpoint.host, "cam.example")
        XCTAssertEqual(endpoint.port, 8554)
        XCTAssertEqual(
            endpoint.resolvedRTSPURL()?.absoluteString,
            "rtsp://u:p@cam.example:8554/live"
        )
    }

    func testProfileDecodesWithoutPTZField() throws {
        let json = """
        [{
            "endpoint": {
                "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "displayName": "Legacy",
                "host": "10.0.0.5",
                "port": 554,
                "path": "/stream",
                "preferredTransport": "tcp"
            },
            "note": "n",
            "lastConnectedAt": null
        }]
        """.data(using: .utf8)!
        let profiles = try JSONDecoder().decode([CameraProfile].self, from: json)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].ptz.backend, .disabled)
        XCTAssertFalse(profiles[0].showsLivePTZOverlay)
    }

    func testProfileEncodesAndDecodesPTZ() throws {
        let http = PTZHTTPConfiguration(
            hostOverride: "ptz.local",
            port: 8080,
            useTLS: false,
            panLeftPath: "/cgi/pan?l=1",
            panRightPath: "",
            tiltUpPath: "",
            tiltDownPath: "",
            zoomInPath: "",
            zoomOutPath: "",
            stopPath: "/cgi/stop"
        )
        let profile = CameraProfile(
            endpoint: CameraEndpoint(displayName: "P", host: "10.0.0.1", path: "/v"),
            note: "",
            ptz: PTZConfiguration(backend: .httpCGI, http: http)
        )
        let data = try JSONEncoder().encode([profile])
        let roundtrip = try JSONDecoder().decode([CameraProfile].self, from: data)
        XCTAssertEqual(roundtrip[0].ptz.backend, .httpCGI)
        XCTAssertEqual(roundtrip[0].ptz.http.panLeftPath, "/cgi/pan?l=1")
        XCTAssertEqual(roundtrip[0].ptz.http.stopPath, "/cgi/stop")
        XCTAssertTrue(roundtrip[0].showsLivePTZOverlay)
    }

    func testProfileONVIFPTZShowsOverlayWhenUsernamePresent() {
        let withUser = CameraProfile(
            endpoint: CameraEndpoint(displayName: "Tapo", host: "10.0.0.1", path: "/s", username: "u"),
            ptz: PTZConfiguration(backend: .onvif, onvif: PTZONVIFConfiguration())
        )
        XCTAssertTrue(withUser.showsLivePTZOverlay)

        let noUser = CameraProfile(
            endpoint: CameraEndpoint(displayName: "Tapo", host: "10.0.0.1", path: "/s", username: nil),
            ptz: PTZConfiguration(backend: .onvif, onvif: PTZONVIFConfiguration())
        )
        XCTAssertFalse(noUser.showsLivePTZOverlay)
    }

    func testProfileEncodesAndDecodesONVIFPTZ() throws {
        let onvif = PTZONVIFConfiguration(hostOverride: "cam.local", port: 2020, useTLS: false)
        let profile = CameraProfile(
            endpoint: CameraEndpoint(displayName: "P", host: "10.0.0.1", path: "/v"),
            ptz: PTZConfiguration(backend: .onvif, onvif: onvif)
        )
        let data = try JSONEncoder().encode([profile])
        let roundtrip = try JSONDecoder().decode([CameraProfile].self, from: data)
        XCTAssertEqual(roundtrip[0].ptz.backend, .onvif)
        XCTAssertEqual(roundtrip[0].ptz.onvif.hostOverride, "cam.local")
        XCTAssertEqual(roundtrip[0].ptz.onvif.port, 2020)
    }

    func testONVIFPresetParsingFromGetPresetsResponse() {
        let xml = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
        <tptz:GetPresetsResponse xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
          <tptz:Preset token="000"><tt:Name xmlns:tt="http://www.onvif.org/ver10/schema">Door</tt:Name></tptz:Preset>
          <tptz:Preset token="001"/>
        </tptz:GetPresetsResponse>
        </s:Body></s:Envelope>
        """
        let presets = ONVIFPTZPresetParsing.presets(from: xml)
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].token, "000")
        XCTAssertEqual(presets[0].name, "Door")
        XCTAssertEqual(presets[0].displayLabel, "Door")
        XCTAssertEqual(presets[1].token, "001")
        XCTAssertNil(presets[1].name)
        XCTAssertEqual(presets[1].displayLabel, "001")
    }

    @MainActor
    func testDuplicatedProfileCopiesPTZ() {
        let ptz = PTZConfiguration(
            backend: .httpCGI,
            http: PTZHTTPConfiguration(
                panLeftPath: "/l",
                stopPath: "/s"
            )
        )
        let original = CameraProfile(
            endpoint: CameraEndpoint(displayName: "Cam", host: "h", path: "/p"),
            note: "note",
            ptz: ptz
        )
        let dup = original.duplicated()
        XCTAssertEqual(dup.ptz.http.panLeftPath, "/l")
        XCTAssertEqual(dup.ptz.http.stopPath, "/s")
        XCTAssertEqual(dup.ptz.backend, .httpCGI)
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
