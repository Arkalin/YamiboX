import Foundation

/// UserDefaults keys the UI layer persists directly via `@AppStorage`.
/// Declared in Core so the views and `resetApplicationData()` share one
/// list — a key added here is automatically considered for reset coverage,
/// where a stringly-typed inline key would silently escape it.
public enum YamiboAppStorageKey {
    public static let favoriteTagSortOrder = "yamibox.favorite.tag.sort"
    public static let loginUsername = "yamibox.login.username"

    /// Keys wiped by "reset application data". The remembered login
    /// username is deliberately excluded: resetting app data should not
    /// also forget which forum account the user habitually signs in with.
    public static let resettable: [String] = [
        favoriteTagSortOrder
    ]
}
