import Foundation

/// Per-board reader-mode configuration (板块阅读方式可插拔配置).
///
/// A single `[fid: Entry]` map is the whole model: a board with no entry uses
/// the plain thread reader, `.normal` records an *explicit* plain-reader
/// choice (see below), `.novel` opens the novel reader, and `.manga` opens
/// the manga reader with an embedded Smart Comic Mode bit. The smart bit only
/// exists on `.manga` — the type cannot express "novel board with smart on".
///
/// `.normal` vs no entry (pluggable-reader-config R12): both classify and
/// route exactly like a plain board. The one behavioral difference is the
/// favorites open dispatch (R11) — an explicit `.normal` entry forces the
/// plain thread reader even for favorites whose stored kind is novel/manga,
/// whereas a board with no entry falls back to each favorite's stored kind.
/// Switching a previously-configured board "back to 普通" therefore writes a
/// `.normal` entry instead of removing the entry.
///
/// One rule, no special cases (pluggable-reader-config decision #4): a board
/// is smart-enabled iff it is currently configured as `.manga(smartEnabled:
/// true)`. Unconfigured boards, `.normal`/`.novel` boards, and a
/// missing/blank fid all report `false` — they behave exactly like plain
/// threads. Callers must query this configuration (or a launch-context
/// snapshot stamped from it) explicitly; never infer mode from proxy signals
/// such as a resolved directory or a non-nil clean book name.
public struct BoardReaderSettings: Codable, Hashable, Sendable {
    public enum ReaderMode: Codable, Hashable, Sendable {
        case normal
        case novel
        case manga(smartEnabled: Bool)
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var mode: ReaderMode
        /// Display-only snapshot of the board name, refreshed whenever the
        /// user visits the board page. `nil` means no snapshot yet — the
        /// presentation layer falls back to a "板块 N" placeholder; never
        /// bake that placeholder string into storage.
        public var boardName: String?

        public init(mode: ReaderMode, boardName: String? = nil) {
            self.mode = mode
            self.boardName = boardName
        }
    }

    /// fid -> entry. No entry = plain thread reader.
    public var entries: [String: Entry]

    /// Factory default carried over from the previous hardcoded taxonomy,
    /// with board names resolved via the authoritative section list in
    /// yamibo-api's `YamiboConstant.kt`: 49/55/60 novel (文學區, 轻小说/译文
    /// 区, TXT小说区), 30 manga with smart on (中文百合漫画区), 46/37 manga
    /// with smart off (原创图作区, 百合漫画图源区).
    public static let factoryDefault = BoardReaderSettings(entries: [
        "49": Entry(mode: .novel, boardName: L10n.string("settings.board_reader.board_name.literature")),
        "55": Entry(mode: .novel, boardName: L10n.string("settings.board_reader.board_name.translated_light_novel")),
        "60": Entry(mode: .novel, boardName: L10n.string("settings.board_reader.board_name.txt_novel")),
        "30": Entry(mode: .manga(smartEnabled: true), boardName: L10n.string("settings.board_reader.board_name.translated_yuri_manga")),
        "46": Entry(mode: .manga(smartEnabled: false), boardName: L10n.string("settings.board_reader.board_name.original_work")),
        "37": Entry(mode: .manga(smartEnabled: false), boardName: L10n.string("settings.board_reader.board_name.yuri_manga_source"))
    ])

    /// The default init IS the factory default (non-empty map), so decode
    /// fallback / reset / fresh install all keep the carried-over behavior.
    public init(entries: [String: Entry] = Self.factoryDefault.entries) {
        self.entries = entries
    }

    public func entry(forumID: String?) -> Entry? {
        guard let normalized = Self.normalizedForumID(forumID) else { return nil }
        return entries[normalized]
    }

    /// One rule, no special cases: only a board currently configured as
    /// `.manga(smartEnabled: true)` reports `true`.
    public func isSmartComicModeEnabled(forumID: String?) -> Bool {
        guard case .manga(smartEnabled: true) = entry(forumID: forumID)?.mode else {
            return false
        }
        return true
    }

    /// Configuration-driven classification: `.novel`/`.manga` from the
    /// configured entry, `.unknown` for unconfigured boards, missing fids,
    /// AND explicit `.normal` entries — an explicit 普通 choice classifies
    /// and routes exactly like an unconfigured board (its only behavioral
    /// difference lives in the favorites open dispatch, R11/R12).
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

    /// Whether any board is configured as `.manga(smartEnabled: true)` —
    /// gates the "智能漫画" source-filter chip's visibility (decision #9
    /// translation); matching stays per-favorite-board.
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
