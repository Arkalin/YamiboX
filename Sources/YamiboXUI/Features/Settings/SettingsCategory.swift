import Foundation
import UIKit
import YamiboXCore

public enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general
    case bookshelf
    case forum
    case favorites
    case reading
    case storage

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            L10n.string("settings.section.general")
        case .bookshelf:
            L10n.string("tab.bookshelf")
        case .forum:
            L10n.string("settings.section.forum")
        case .favorites:
            L10n.string("settings.section.favorites")
        case .reading:
            L10n.string("settings.section.reading")
        case .storage:
            L10n.string("settings.section.data_storage")
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .bookshelf: "books.vertical"
        case .forum: "text.bubble"
        case .favorites: "heart.text.square"
        case .reading: "book"
        case .storage: "externaldrive"
        }
    }
}

/// One searchable settings entry. `keywords` supplements `title` with
/// synonyms so e.g. "缓存"/"清理"/"空间" all surface the storage-clearing
/// rows even though none of those words appear in the row's own title.
struct SettingsSearchEntry: Identifiable {
    let id: String
    let title: String
    let category: SettingsCategory
    let keywords: [String]

    var breadcrumb: String {
        "\(category.title) · \(title)"
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        if title.localizedCaseInsensitiveContains(needle) { return true }
        return keywords.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// Main-actor isolated because the entry list is device-dependent (the iPad
/// idiom check below); its only consumer is the settings home view's search.
@MainActor
enum SettingsSearchRegistry {
    static let entries: [SettingsSearchEntry] = {
        var entries = baseEntries
        // The grid card size slider only exists on iPad (see
        // `SettingsFavoritesView`); registering it on iPhone would surface a
        // search hit that leads to a page without the row.
        if UIDevice.current.userInterfaceIdiom == .pad {
            let scaleEntry = SettingsSearchEntry(
                id: "favorites.grid_card_scale",
                title: L10n.string("settings.favorite_grid_card_scale"),
                category: .favorites,
                keywords: localizedKeywords("settings.search.keywords.favorites.grid_card_scale")
            )
            if let backgroundIndex = entries.firstIndex(where: { $0.id == "favorites.background" }) {
                entries.insert(scaleEntry, at: backgroundIndex + 1)
            } else {
                entries.append(scaleEntry)
            }
        }
        return entries
    }()

    private static let baseEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "general.launch_background",
            title: L10n.string("settings.launch_background"),
            category: .general,
            keywords: localizedKeywords("settings.search.keywords.general.launch_background")
        ),
        SettingsSearchEntry(
            id: "bookshelf.only_favorites",
            title: L10n.string("settings.bookshelf.only_favorites"),
            category: .bookshelf,
            keywords: localizedKeywords("settings.search.keywords.bookshelf.only_favorites")
        ),
        SettingsSearchEntry(
            id: "bookshelf.background",
            title: L10n.string("settings.bookshelf.background"),
            category: .bookshelf,
            keywords: localizedKeywords("settings.search.keywords.bookshelf.background")
        ),
        SettingsSearchEntry(
            id: "bookshelf.continue_count",
            title: L10n.string("home.continue"),
            category: .bookshelf,
            keywords: localizedKeywords("settings.search.keywords.bookshelf.continue_count")
        ),
        SettingsSearchEntry(
            id: "general.navigation",
            title: L10n.string("settings.navigation.title"),
            category: .general,
            keywords: localizedKeywords("settings.search.keywords.general.navigation")
        ),
        SettingsSearchEntry(
            id: "general.appearance",
            title: L10n.string("settings.app_theme"),
            category: .general,
            keywords: localizedKeywords("settings.search.keywords.general.appearance")
        ),
        SettingsSearchEntry(
            id: "forum.auto_sign_in",
            title: L10n.string("settings.auto_sign_in"),
            category: .forum,
            keywords: localizedKeywords("settings.search.keywords.forum.auto_sign_in")
        ),
        SettingsSearchEntry(
            id: "forum.enhanced_check_in",
            title: L10n.string("settings.enhanced_check_in"),
            category: .forum,
            keywords: localizedKeywords("settings.search.keywords.forum.enhanced_check_in")
        ),
        SettingsSearchEntry(
            id: "forum.board_reader",
            title: L10n.string("settings.section.board_reader"),
            category: .forum,
            keywords: localizedKeywords("settings.search.keywords.forum.board_reader")
        ),
        SettingsSearchEntry(
            id: "favorites.layout",
            title: L10n.string("favorites.layout"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.layout")
        ),
        SettingsSearchEntry(
            id: "favorites.sort",
            title: L10n.string("favorites.sort"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.sort")
        ),
        SettingsSearchEntry(
            id: "favorites.item_tap_action",
            title: L10n.string("settings.favorite_item_tap_action"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.item_tap_action")
        ),
        SettingsSearchEntry(
            id: "favorites.background",
            title: L10n.string("settings.favorite_background"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.background")
        ),
        SettingsSearchEntry(
            id: "favorites.sync_behavior",
            title: L10n.string("settings.section.favorite_sync_behavior"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.sync_behavior")
        ),
        SettingsSearchEntry(
            id: "favorites.updates_interval",
            title: L10n.string("favorites.updates.interval"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.updates_interval")
        ),
        SettingsSearchEntry(
            id: "favorites.updates_notifications",
            title: L10n.string("favorites.updates.notifications"),
            category: .favorites,
            keywords: localizedKeywords("settings.search.keywords.favorites.updates_notifications")
        ),
        SettingsSearchEntry(
            id: "reading.chapter_comments",
            title: L10n.string("settings.chapter_comments.title"),
            category: .reading,
            keywords: localizedKeywords("settings.search.keywords.reading.chapter_comments")
        ),
        SettingsSearchEntry(
            id: "reading.novel_download",
            title: L10n.string("settings.section.novel_download"),
            category: .reading,
            keywords: localizedKeywords("settings.search.keywords.reading.novel_download")
        ),
        SettingsSearchEntry(
            id: "peripherals.apple_pencil",
            title: L10n.string("apple_pencil.page_turn"),
            category: .reading,
            keywords: localizedKeywords("settings.search.keywords.peripherals.apple_pencil")
        ),
        SettingsSearchEntry(
            id: "peripherals.gamepad",
            title: L10n.string("settings.gamepad"),
            category: .reading,
            keywords: localizedKeywords("settings.search.keywords.peripherals.gamepad")
        ),
        SettingsSearchEntry(
            id: "peripherals.keyboard",
            title: L10n.string("settings.keyboard"),
            category: .reading,
            keywords: localizedKeywords("settings.search.keywords.peripherals.keyboard")
        ),
        SettingsSearchEntry(
            id: "storage.webdav",
            title: L10n.string("settings.webdav_sync"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.webdav")
        ),
        SettingsSearchEntry(
            id: "storage.clear_web_reader_cache",
            title: L10n.string("settings.clear_web_reader_cache"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.clear_web_reader_cache")
        ),
        SettingsSearchEntry(
            id: "storage.clear_image_cache",
            title: L10n.string("settings.clear_image_cache"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.clear_image_cache")
        ),
        SettingsSearchEntry(
            id: "storage.clear_other_caches",
            title: L10n.string("settings.clear_other_caches"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.clear_other_caches")
        ),
        SettingsSearchEntry(
            id: "storage.clear_content_covers",
            title: L10n.string("settings.clear_content_covers"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.clear_content_covers")
        ),
        SettingsSearchEntry(
            id: "storage.clear_reading_progress",
            title: L10n.string("settings.clear_reading_progress"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.clear_reading_progress")
        ),
        SettingsSearchEntry(
            id: "storage.clear_browsing_history",
            title: L10n.string("settings.clear_browsing_history"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.clear_browsing_history")
        ),
        SettingsSearchEntry(
            id: "storage.manga_directory",
            title: L10n.string("settings.manga_directory.cleanup"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.manga_directory")
        ),
        SettingsSearchEntry(
            id: "storage.download",
            title: L10n.string("settings.download.cleanup"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.download")
        ),
        SettingsSearchEntry(
            id: "storage.network_logs",
            title: L10n.string("settings.network_log.title"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.network_logs")
        ),
        SettingsSearchEntry(
            id: "storage.reset_application",
            title: L10n.string("settings.reset_application"),
            category: .storage,
            keywords: localizedKeywords("settings.search.keywords.storage.reset_application")
        )
    ]

    private static func localizedKeywords(_ key: String) -> [String] {
        L10n.string(key).split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func search(_ query: String) -> [SettingsSearchEntry] {
        entries.filter { $0.matches(query) }
    }
}
