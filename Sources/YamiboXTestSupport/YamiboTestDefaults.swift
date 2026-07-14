import Foundation
import YamiboXCore

public enum YamiboTestDefaults {
    public static func suiteName(prefix: String) -> String {
        "yamibo-tests.\(prefix).\(UUID().uuidString)"
    }

    public static func make(prefix: String) throws -> UserDefaults {
        try make(suiteName: suiteName(prefix: prefix))
    }

    public static func make(suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(
                domain: "YamiboTestDefaults",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create UserDefaults suite \(suiteName)"]
            )
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    public static func defaults(suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(
                domain: "YamiboTestDefaults",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create UserDefaults suite \(suiteName)"]
            )
        }
        return defaults
    }
}

public extension ReadingProgressStore {
    init(testSuiteName suiteName: String, key: String) throws {
        self.init(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: key
        )
    }
}

public extension ReaderResumeRouteStore {
    convenience init(testSuiteName suiteName: String, key: String) throws {
        self.init(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: key)
    }
}

public extension SessionStore {
    init(testSuiteName suiteName: String, key: String) throws {
        self.init(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: key)
    }
}

public extension SettingsStore {
    init(testSuiteName suiteName: String, key: String) throws {
        self.init(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: key)
    }
}

public extension WebDAVSyncSettingsStore {
    init(testSuiteName suiteName: String, key: String) throws {
        self.init(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: key)
    }
}

public extension YamiboProfileStore {
    init(testSuiteName suiteName: String, key: String) throws {
        self.init(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: key)
    }
}
