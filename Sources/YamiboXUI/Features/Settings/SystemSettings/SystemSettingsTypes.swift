import Foundation
import YamiboXCore

enum SystemSettingsAction: Equatable {
    case loading
    case clearingWebReaderCache
    case clearingContentCoverCache
    case clearingOtherCaches
    case clearingImageCache
    case clearingReadingProgress
    case clearingBrowsingHistory
    case clearingDownload
    case clearingMangaDirectory
    case resettingApplication
}

enum SystemSettingsConfirmation: String, Identifiable {
    case clearWebReaderCache
    case clearContentCoverCache
    case clearOtherCaches
    case clearImageCache
    case clearReadingProgress
    case clearBrowsingHistory
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
        case .clearReadingProgress:
            L10n.string("settings.confirm_clear_reading_progress")
        case .clearBrowsingHistory:
            L10n.string("history.clear_all.title")
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
        case .clearWebReaderCache, .clearContentCoverCache, .clearOtherCaches, .clearImageCache,
             .clearReadingProgress, .clearBrowsingHistory:
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
        case .clearReadingProgress:
            L10n.string("settings.clear_reading_progress_message")
        case .clearBrowsingHistory:
            L10n.string("history.clear_all.message")
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
        id = summary.id.rawValue
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
/// "delete selected" action, mirroring `DownloadManagementSelectionActions`.
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
