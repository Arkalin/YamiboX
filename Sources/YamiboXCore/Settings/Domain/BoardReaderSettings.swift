import Foundation

public struct BoardReaderSettings: Codable, Hashable, Sendable {
    public enum ReaderMode: Codable, Hashable, Sendable {
        case normal
        case novel
        case manga(smartEnabled: Bool)
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var mode: ReaderMode
        public var boardName: String?

        public init(mode: ReaderMode, boardName: String? = nil) {
            self.mode = mode
            self.boardName = boardName
        }
    }

    public var entries: [String: Entry]

    public static let factoryDefault = BoardReaderSettings(entries: [
        "49": Entry(mode: .novel, boardName: L10n.string("settings.board_reader.board_name.literature")),
        "55": Entry(mode: .novel, boardName: L10n.string("settings.board_reader.board_name.translated_light_novel")),
        "60": Entry(mode: .novel, boardName: L10n.string("settings.board_reader.board_name.txt_novel")),
        "30": Entry(mode: .manga(smartEnabled: true), boardName: L10n.string("settings.board_reader.board_name.translated_yuri_manga")),
        "46": Entry(mode: .manga(smartEnabled: false), boardName: L10n.string("settings.board_reader.board_name.original_work")),
        "37": Entry(mode: .manga(smartEnabled: false), boardName: L10n.string("settings.board_reader.board_name.yuri_manga_source"))
    ])

    public init(entries: [String: Entry] = Self.factoryDefault.entries) {
        self.entries = entries
    }

    public func entry(forumID: String?) -> Entry? {
        guard let normalized = Self.normalizedForumID(forumID) else { return nil }
        return entries[normalized]
    }

    public func isSmartComicModeEnabled(forumID: String?) -> Bool {
        guard case .manga(smartEnabled: true) = entry(forumID: forumID)?.mode else {
            return false
        }
        return true
    }

    public func threadKind(forumID: String?) -> YamiboThreadKind {
        switch entry(forumID: forumID)?.mode {
        case .novel:
            return .novel
        case .manga:
            return .manga
        case .normal, nil:
            return .unknown
        }
    }

    public var hasAnySmartEnabledBoard: Bool {
        entries.values.contains { entry in
            if case .manga(smartEnabled: true) = entry.mode { return true }
            return false
        }
    }

    public mutating func setEntry(_ entry: Entry, forumID: String?) {
        guard let normalized = Self.normalizedForumID(forumID) else { return }
        entries[normalized] = entry
    }

    public mutating func removeEntry(forumID: String?) {
        guard let normalized = Self.normalizedForumID(forumID) else { return }
        entries.removeValue(forKey: normalized)
    }

    private static func normalizedForumID(_ forumID: String?) -> String? {
        guard let normalized = forumID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
