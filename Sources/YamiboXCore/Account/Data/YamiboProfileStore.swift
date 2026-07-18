import Foundation

public actor YamiboProfileStore {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let storage: UserDefaultsJSONStorage<YamiboProfile>

    public init(defaults: UserDefaults = .standard, key: String = "yamibox.profile") {
        self.storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.account.error("Failed to decode stored profile data: \(error)")
        }
    }

    public func load() async -> YamiboProfile? {
        storage.loadStored()
    }

    public func save(_ profile: YamiboProfile) async throws {
        try storage.save(profile)
        postChangeNotification()
    }

    public func clear() async {
        storage.removeValue()
        postChangeNotification()
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
