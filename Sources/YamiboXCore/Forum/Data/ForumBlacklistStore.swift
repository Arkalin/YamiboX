import Foundation

/// A local cache of the server's account-scoped list, not a second block list.
public actor ForumBlacklistStore {
    private struct State: Codable {
        var accounts: [String: [ForumBlacklistEntry]] = [:]
        var replyDisplay: ForumBlockedReplyDisplay = .placeholder
    }

    private let storage: UserDefaultsJSONStorage<State>

    public init(defaults: UserDefaults = .standard, key: String = "yamibox.forum.blacklist") {
        storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.persistence.error("Failed to decode blacklist cache: \(error)")
        }
    }

    func entries(accountKey: String) -> [ForumBlacklistEntry] {
        storage.load(default: State()).accounts[accountKey] ?? []
    }

    func save(_ entries: [ForumBlacklistEntry], accountKey: String) throws {
        var state = storage.load(default: State())
        state.accounts[accountKey] = entries
        try storage.save(state)
    }

    func replyDisplay() -> ForumBlockedReplyDisplay {
        storage.load(default: State()).replyDisplay
    }

    func saveReplyDisplay(_ display: ForumBlockedReplyDisplay) throws {
        var state = storage.load(default: State())
        state.replyDisplay = display
        try storage.save(state)
    }

    public func clearAll() {
        storage.removeValue()
    }
}
