import Foundation

public enum YamiboAppStorageKey {
    public static let favoriteTagSortOrder = "yamibox.favorite.tag.sort"
    public static let loginUsername = "yamibox.login.username"
    public static let appUpdateSkippedVersion = "yamibox.app_update.skipped_version"
    public static let readerSearchHistory = "yamibox.reader.search.history"
    public static let novelDetailChapterLayout = "yamibox.novel.detail.chapter_layout"
    public static let mangaDetailChapterLayout = "yamibox.manga.detail.chapter_layout"
    public static let readerDefaultHighlightStyle = "yamibox.reader.default_highlight_style"

    public static let resettable: [String] = [
        favoriteTagSortOrder,
        appUpdateSkippedVersion,
        readerDefaultHighlightStyle,
        readerSearchHistory,
        novelDetailChapterLayout,
        mangaDetailChapterLayout
    ]
}
