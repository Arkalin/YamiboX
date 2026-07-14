import Foundation

public actor YamiboProfileStore {
    public static let didChangeNotification = Notification.Name("yamibox.profileStore.didChange")
    public static let changeIDUserInfoKey = "changeID"

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "yamibox.profile") {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> YamiboProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(YamiboProfile.self, from: data)
        } catch {
            YamiboLog.account.error("Failed to decode stored profile data: \(error)")
            return nil
        }
    }

    public func save(_ profile: YamiboProfile) async throws {
        do {
            let data = try encoder.encode(profile)
            defaults.set(data, forKey: key)
            postChangeNotification()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clear() async {
        defaults.removeObject(forKey: key)
        postChangeNotification()
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }
}
