import Foundation
import YamiboXCore

enum SystemSettingsAction: Equatable {
    case loading
    case clearingWebReaderCache
    case clearingContentCoverCache
    case clearingOtherCaches
    case clearingImageCache
    case clearingOfflineCache
    case clearingMangaDirectory
    case resettingApplication
}

struct OfflineCacheManagementRow: Hashable, Identifiable {
    var id: OfflineCacheGroupID
    var readerKind: OfflineCacheReaderKind
    var title: String
    var byteCount: Int
    var cachedCount: Int
    var pendingCount: Int
    var failedCount: Int
    var entries: [OfflineCacheManagementEntry]

    init(group: OfflineCacheManagementGroup) {
        id = group.id
        readerKind = group.id.readerKind
        title = group.title
        byteCount = group.byteCount
        cachedCount = group.cachedCount
        pendingCount = group.pendingCount
        failedCount = group.failedCount
        entries = group.entries
    }

    var byteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(max(0, byteCount)))
    }

    var summaryText: String {
        var pieces = [
            L10n.string("settings.offline_cache.entry_count_format", entries.count),
            byteCountLabel
        ]
        if pendingCount > 0 {
            pieces.append(L10n.string("settings.offline_cache.pending_count_format", pendingCount))
        }
        if failedCount > 0 {
            pieces.append(L10n.string("settings.offline_cache.failed_count_format", failedCount))
        }
        return pieces.joined(separator: " · ")
    }
}

struct OfflineCacheManagementSelectionActionState: Equatable {
    let selectedGroupCount: Int
    let canDelete: Bool
}

struct OfflineCacheManagementConfirmation: Identifiable, Equatable {
    var groupIDs: [OfflineCacheGroupID]
    var entryIDs: [OfflineCacheEntryID]
    var titles: [String]

    var id: String {
        let groupPart = groupIDs.map { "\($0.readerKind.rawValue):\($0.ownerKey)" }.joined(separator: "|")
        let entryPart = entryIDs.map {
            "\($0.readerKind.rawValue):\($0.ownerKey):\($0.entryKey)"
        }.joined(separator: "|")
        return [groupPart, entryPart].filter { !$0.isEmpty }.joined(separator: "#")
    }

    init(groupIDs: [OfflineCacheGroupID] = [], entryIDs: [OfflineCacheEntryID] = [], titles: [String]) {
        self.groupIDs = groupIDs
        self.entryIDs = entryIDs
        self.titles = titles
    }

    var title: String {
        if isEntryDeletion {
            return L10n.string("settings.offline_cache.confirm_entry_title")
        }
        if groupIDs.count == 1 {
            return L10n.string("settings.offline_cache.confirm_single_title")
        }
        return L10n.string("settings.offline_cache.confirm_batch_title")
    }

    var message: String {
        if isEntryDeletion {
            if let firstTitle = titles.first, entryIDs.count == 1 {
                return L10n.string("settings.offline_cache.confirm_entry_message", firstTitle)
            }
            return L10n.string("settings.offline_cache.confirm_entry_batch_message", entryIDs.count)
        }
        if let firstTitle = titles.first, groupIDs.count == 1 {
            return L10n.string("settings.offline_cache.confirm_single_message", firstTitle)
        }
        return L10n.string("settings.offline_cache.confirm_batch_message", groupIDs.count)
    }

    private var isEntryDeletion: Bool {
        !entryIDs.isEmpty
    }
}

enum SystemSettingsConfirmation: String, Identifiable {
    case clearWebReaderCache
    case clearContentCoverCache
    case clearOtherCaches
    case clearImageCache
    case restoreBoardReaderDefaults
    case resetApplication
    case signOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clearWebReaderCache:
            L10n.string("settings.confirm_clear_web_reader_cache")
        case .clearContentCoverCache:
            L10n.string("settings.confirm_clear_content_cover_cache")
        case .clearOtherCaches:
            L10n.string("settings.confirm_clear_other_caches")
        case .clearImageCache:
            L10n.string("settings.confirm_clear_image_cache")
        case .restoreBoardReaderDefaults:
            L10n.string("settings.board_reader.confirm_restore_default")
        case .resetApplication:
            L10n.string("settings.confirm_reset_application")
        case .signOut:
            L10n.string("settings.confirm_sign_out")
        }
    }

    var buttonTitle: String {
        switch self {
        case .clearWebReaderCache, .clearContentCoverCache, .clearOtherCaches, .clearImageCache:
            L10n.string("common.clear")
        case .restoreBoardReaderDefaults:
            L10n.string("settings.board_reader.restore")
        case .resetApplication:
            L10n.string("settings.reset")
        case .signOut:
            L10n.string("mine.sign_out")
        }
    }

    var message: String {
        switch self {
        case .clearWebReaderCache:
            L10n.string("settings.clear_web_reader_cache_message")
        case .clearContentCoverCache:
            L10n.string("settings.clear_content_cover_cache_message")
        case .clearOtherCaches:
            L10n.string("settings.clear_other_caches_message")
        case .clearImageCache:
            L10n.string("settings.clear_image_cache_message")
        case .restoreBoardReaderDefaults:
            L10n.string("settings.board_reader.restore_default_message")
        case .resetApplication:
            L10n.string("settings.reset_application_message")
        case .signOut:
            L10n.string("settings.sign_out_message")
        }
    }
}

struct MangaDirectoryManagementRow: Hashable, Identifiable {
    var id: String
    var title: String
    var chapterCount: Int

    init(summary: MangaDirectorySummary) {
        id = summary.cleanBookName
        title = summary.cleanBookName
        chapterCount = summary.chapterCount
    }

    var summaryText: String {
        L10n.string("settings.manga_directory.chapter_count_format", chapterCount)
    }
}

struct MangaDirectoryManagementConfirmation: Identifiable, Equatable {
    var directoryIDs: [String]
    var titles: [String]

    var id: String { directoryIDs.sorted().joined(separator: "|") }

    init(directoryIDs: [String], titles: [String]) {
        self.directoryIDs = directoryIDs
        self.titles = titles
    }

    var title: String {
        directoryIDs.count == 1
            ? L10n.string("settings.manga_directory.confirm_single_title")
            : L10n.string("settings.manga_directory.confirm_batch_title")
    }

    var message: String {
        if let firstTitle = titles.first, directoryIDs.count == 1 {
            return L10n.string("settings.manga_directory.confirm_single_message", firstTitle)
        }
        return L10n.string("settings.manga_directory.confirm_batch_message", directoryIDs.count)
    }
}

/// Builds the manga-directory management selection-mode bottom bar's single
/// "delete selected" action, mirroring `OfflineCacheManagementSelectionActions`.
enum MangaDirectoryManagementSelectionActions {
    static func delete(
        selectedCount: Int,
        canDelete: Bool,
        onDelete: @escaping () -> Void
    ) -> [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "delete",
                title: L10n.string("common.delete"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: canDelete,
                accessibilityLabel: L10n.string(
                    "settings.manga_directory.delete_selected_format",
                    selectedCount
                ),
                action: onDelete
            )
        ]
    }
}
