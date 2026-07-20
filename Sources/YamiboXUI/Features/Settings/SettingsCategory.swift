import Foundation
import UIKit
import YamiboXCore

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case favorites
    case reading
    case peripherals
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            L10n.string("settings.section.general")
        case .favorites:
            L10n.string("settings.section.favorites")
        case .reading:
            L10n.string("settings.section.reading")
        case .peripherals:
            L10n.string("settings.peripheral_behavior")
        case .storage:
            L10n.string("settings.section.data_storage")
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .favorites: "star"
        case .reading: "book"
        case .peripherals: "gamecontroller"
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
                keywords: ["卡片", "大小", "缩放", "网格", "瀑布流", "外观"]
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
            id: "general.home_page",
            title: L10n.string("settings.home_page"),
            category: .general,
            keywords: ["主页", "首页", "论坛", "收藏"]
        ),
        SettingsSearchEntry(
            id: "general.auto_sign_in",
            title: L10n.string("settings.auto_sign_in"),
            category: .general,
            keywords: ["签到", "自动化", "快捷指令"]
        ),
        SettingsSearchEntry(
            id: "favorites.layout",
            title: L10n.string("favorites.layout"),
            category: .favorites,
            keywords: ["布局", "网格", "瀑布流", "封面"]
        ),
        SettingsSearchEntry(
            id: "favorites.sort",
            title: L10n.string("favorites.sort"),
            category: .favorites,
            keywords: ["排序", "顺序"]
        ),
        SettingsSearchEntry(
            id: "favorites.background",
            title: L10n.string("settings.favorite_background"),
            category: .favorites,
            keywords: ["背景", "壁纸", "外观"]
        ),
        SettingsSearchEntry(
            id: "favorites.sync_behavior",
            title: L10n.string("settings.section.favorite_sync_behavior"),
            category: .favorites,
            keywords: ["同步", "百合会", "上传", "下载"]
        ),
        SettingsSearchEntry(
            id: "favorites.updates_interval",
            title: L10n.string("favorites.updates.interval"),
            category: .favorites,
            keywords: ["更新检查", "自动检查", "后台刷新"]
        ),
        SettingsSearchEntry(
            id: "favorites.updates_notifications",
            title: L10n.string("favorites.updates.notifications"),
            category: .favorites,
            keywords: ["通知", "提醒", "推送"]
        ),
        SettingsSearchEntry(
            id: "reading.board_reader",
            title: L10n.string("settings.section.board_reader"),
            category: .reading,
            keywords: ["板块", "阅读方式", "漫画", "小说", "智能漫画"]
        ),
        SettingsSearchEntry(
            id: "reading.novel_offline_cache",
            title: L10n.string("settings.section.novel_offline_cache"),
            category: .reading,
            keywords: ["小说", "离线", "缓存", "内嵌图片", "自动刷新"]
        ),
        SettingsSearchEntry(
            id: "peripherals.apple_pencil",
            title: L10n.string("apple_pencil.page_turn"),
            category: .peripherals,
            keywords: ["Apple Pencil", "翻页", "iPad"]
        ),
        SettingsSearchEntry(
            id: "peripherals.gamepad",
            title: L10n.string("settings.gamepad"),
            category: .peripherals,
            keywords: ["手柄", "控制器", "按键绑定"]
        ),
        SettingsSearchEntry(
            id: "peripherals.keyboard",
            title: L10n.string("settings.keyboard"),
            category: .peripherals,
            keywords: ["键盘", "按键绑定"]
        ),
        SettingsSearchEntry(
            id: "storage.webdav",
            title: L10n.string("settings.webdav_sync"),
            category: .storage,
            keywords: ["WebDAV", "备份", "同步"]
        ),
        SettingsSearchEntry(
            id: "storage.clear_web_reader_cache",
            title: L10n.string("settings.clear_web_reader_cache"),
            category: .storage,
            keywords: ["清理", "清除", "缓存", "空间", "网页", "论坛", "小说", "漫画", "阅读器"]
        ),
        SettingsSearchEntry(
            id: "storage.clear_image_cache",
            title: L10n.string("settings.clear_image_cache"),
            category: .storage,
            keywords: ["清除", "缓存", "空间", "图片"]
        ),
        SettingsSearchEntry(
            id: "storage.clear_content_cover_cache",
            title: L10n.string("settings.clear_content_cover_cache"),
            category: .storage,
            keywords: ["清理", "缓存", "空间", "封面", "索引"]
        ),
        SettingsSearchEntry(
            id: "storage.clear_other_caches",
            title: L10n.string("settings.clear_other_caches"),
            category: .storage,
            keywords: ["清理", "缓存", "其他", "签到", "收藏更新", "网络"]
        ),
        SettingsSearchEntry(
            id: "storage.manga_directory",
            title: L10n.string("settings.manga_directory.cleanup"),
            category: .storage,
            keywords: ["漫画", "目录", "索引", "清理", "分组"]
        ),
        SettingsSearchEntry(
            id: "storage.offline_cache",
            title: L10n.string("settings.offline_cache.cleanup"),
            category: .storage,
            keywords: ["离线缓存", "管理", "清理"]
        ),
        SettingsSearchEntry(
            id: "storage.reset_application",
            title: L10n.string("settings.reset_application"),
            category: .storage,
            keywords: ["初始化", "重置", "清空", "恢复出厂"]
        )
    ]

    static func search(_ query: String) -> [SettingsSearchEntry] {
        entries.filter { $0.matches(query) }
    }
}
