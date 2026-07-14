import CryptoKit
import Foundation

public struct YamiboCheckInSnapshot: Codable, Equatable, Sendable {
    public var checkedInDatesByAccountHash: [String: String]

    public init(checkedInDatesByAccountHash: [String: String] = [:]) {
        self.checkedInDatesByAccountHash = checkedInDatesByAccountHash
    }
}

public actor YamiboCheckInStore {
    public static let didChangeNotification = Notification.Name("yamibox.checkInStore.didChange")
    public static let changeIDUserInfoKey = "changeID"

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let calendar: Calendar
    private let formatter: DateFormatter

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "yamibox.autoSign.lastDate"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        self.calendar = calendar

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        self.formatter = formatter
    }

    public func needsCheckIn(session: SessionState) async -> Bool {
        guard let key = storageKey(for: session) else { return true }
        return defaults.string(forKey: key) != currentDateString()
    }

    public func markCheckedIn(session: SessionState) async {
        guard let key = storageKey(for: session) else { return }
        defaults.set(currentDateString(), forKey: key)
        postChangeNotification()
    }

    public func lastCheckedInDate(session: SessionState) async -> String? {
        guard let key = storageKey(for: session) else { return nil }
        return defaults.string(forKey: key)
    }

    public func clearAll() async {
        let prefix = "\(keyPrefix)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        postChangeNotification()
    }

    public func exportSnapshot() async -> YamiboCheckInSnapshot {
        let prefix = "\(keyPrefix)."
        let values = defaults.dictionaryRepresentation().reduce(into: [String: String]()) { partial, item in
            guard item.key.hasPrefix(prefix), let date = item.value as? String else { return }
            let hash = String(item.key.dropFirst(prefix.count))
            guard !hash.isEmpty else { return }
            partial[hash] = date
        }
        return YamiboCheckInSnapshot(checkedInDatesByAccountHash: values)
    }

    public func importSnapshot(_ snapshot: YamiboCheckInSnapshot) async {
        let prefix = "\(keyPrefix)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        for (hash, date) in snapshot.checkedInDatesByAccountHash where !hash.isEmpty && !date.isEmpty {
            defaults.set(date, forKey: "\(prefix)\(hash)")
        }
        postChangeNotification()
    }

    private func storageKey(for session: SessionState) -> String? {
        guard let hash = accountHash(from: session.cookie) else { return nil }
        return "\(keyPrefix).\(hash)"
    }

    private func currentDateString() -> String {
        formatter.string(from: Date())
    }

    private func accountHash(from cookie: String) -> String? {
        guard let authValue = SessionState.authenticationCookieValue(in: cookie) else {
            return nil
        }

        let digest = SHA256.hash(data: Data(authValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }
}
