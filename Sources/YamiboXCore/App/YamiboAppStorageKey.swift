import Foundation

/// UserDefaults keys the UI layer persists directly (via `@AppStorage` or
/// plain `UserDefaults` access). Declared in Core so the views and
/// `resetApplicationData()` share one list — a key added here is
/// automatically considered for reset coverage, where a stringly-typed
/// inline key would silently escape it.
public enum YamiboAppStorageKey {
    public static let favoriteTagSortOrder = "yamibox.favorite.tag.sort"
    public static let loginUsername = "yamibox.login.username"
    public static let appUpdateSkippedVersion = "yamibox.app_update.skipped_version"
    public static let readerSearchHistory = "yamibox.reader.search.history"
    /// The highlight style the reader will use for the next annotation —
    /// "whatever I picked last time", global rather than per-work because a
    /// reader's colour semantics (yellow = a good line, blue = setting) stay
    /// stable across books. Local-only on purpose: it is a UI habit, not
    /// content, so it stays out of the synced settings payload.
    public static let readerDefaultHighlightStyle = "yamibox.reader.default_highlight_style"

    /// Keys wiped by "reset application data". The remembered login
    /// username is deliberately excluded: resetting app data should not
    /// also forget which forum account the user habitually signs in with.
    public static let resettable: [String] = [
        favoriteTagSortOrder,
        appUpdateSkippedVersion,
        readerDefaultHighlightStyle,
        readerSearchHistory
    ]
}
