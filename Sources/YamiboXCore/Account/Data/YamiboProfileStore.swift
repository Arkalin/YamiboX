import Foundation

public actor YamiboProfileStore {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    private nonisolated let accountStore: AccountStore?
    public nonisolated var changeID: String { accountStore?.broadcaster.changeID ?? changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> {
        accountStore?.broadcaster.changes() ?? changeBroadcaster.changes()
    }

    private let storage: UserDefaultsJSONStorage<YamiboProfile>?

    public init(accountStore: AccountStore = .shared) {
        self.accountStore = accountStore
        storage = nil
    }

    public init(defaults: UserDefaults, key: String = "yamibox.profile") {
        accountStore = nil
        self.storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.account.error("Failed to decode stored profile data: \(error)")
        }
    }

    public func load() async -> YamiboProfile? {
        if let accountStore { return try? await accountStore.profile() }
        return storage?.loadStored()
    }

    public func save(_ profile: YamiboProfile) async throws {
        try await save(profile, expectedGeneration: nil)
    }

    public func save(_ profile: YamiboProfile, expectedGeneration: UUID?) async throws {
        if let accountStore {
            try await accountStore.saveProfile(profile, expected: expectedGeneration)
            return
        }
        try storage?.save(profile)
        postChangeNotification()
    }

    public func clear() async {
        if let accountStore {
            do { try await accountStore.saveProfile(nil) }
            catch { YamiboLog.account.error("Unable to clear profile: \(error)") }
            return
        }
        storage?.removeValue()
        postChangeNotification()
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
