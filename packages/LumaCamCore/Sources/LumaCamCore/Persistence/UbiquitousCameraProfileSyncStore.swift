import Foundation

/// `NSObject` + KVS notifications are not `Sendable`-friendly; internal access is single-threaded per instance except the main-queue hop below.
public final class UbiquitousCameraProfileSyncStore: NSObject, CameraProfileSyncStore, @unchecked Sendable {
    public var onChange: ((CameraProfileSnapshot) -> Void)?

    private let store: NSUbiquitousKeyValueStore
    private let dataKey: String
    private let timestampKey: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        store: NSUbiquitousKeyValueStore = .default,
        dataKey: String = "LumaCam.iCloud.savedProfiles",
        timestampKey: String = "LumaCam.iCloud.savedProfiles.updatedAt"
    ) {
        self.store = store
        self.dataKey = dataKey
        self.timestampKey = timestampKey
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func loadSnapshot() -> CameraProfileSnapshot? {
        guard
            let data = store.data(forKey: dataKey),
            let profiles = try? decoder.decode([CameraProfile].self, from: data)
        else {
            return nil
        }

        let timestamp = store.object(forKey: timestampKey) as? Double ?? 0
        return CameraProfileSnapshot(
            profiles: profiles,
            updatedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    public func saveSnapshot(_ snapshot: CameraProfileSnapshot) {
        guard let data = try? encoder.encode(snapshot.profiles) else {
            return
        }

        store.set(data, forKey: dataKey)
        store.set(snapshot.updatedAt.timeIntervalSince1970, forKey: timestampKey)
        store.synchronize()
    }

    public func synchronize() {
        store.synchronize()
    }

    @objc private func handleStoreChange(_ notification: Notification) {
        // `didChangeExternally` is delivered off the main queue; clients (e.g. `CameraRegistry`) are MainActor.
        guard let snapshot = loadSnapshot() else { return }
        let callback = onChange
        DispatchQueue.main.async {
            callback?(snapshot)
        }
    }
}
