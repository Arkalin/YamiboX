import SwiftUI
import UIKit
import YamiboXCore

/// Presentation mapping for favorite domain values: user-facing labels and
/// colors live here, not in the library models.
extension FavoriteSourceGroup {
    var displayLabel: String {
        switch self {
        case let .forumBoard(_, label):
            label
        case let .smartManga(_, cleanBookName):
            cleanBookName
        case .unknown:
            L10n.string("favorites.source_group.unknown")
        }
    }
}

extension FavoriteCollectionColor {
    var swiftUIColor: Color {
        switch self {
        case .red:
            .red
        case .orange:
            .orange
        case .yellow:
            .yellow
        case .green:
            .green
        case .blue:
            .blue
        case .purple:
            .purple
        case .pink:
            .pink
        case .gray:
            .gray
        }
    }

    var localizedTitle: String {
        switch self {
        case .red:
            L10n.string("color.red")
        case .orange:
            L10n.string("color.orange")
        case .yellow:
            L10n.string("color.yellow")
        case .green:
            L10n.string("color.green")
        case .blue:
            L10n.string("color.blue")
        case .purple:
            L10n.string("color.purple")
        case .pink:
            L10n.string("color.pink")
        case .gray:
            L10n.string("color.gray")
        }
    }

    /// A `circle.fill` baked to this color at the bitmap level via
    /// `.alwaysOriginal`. Plain `Image(systemName:).foregroundStyle(_:)`
    /// renders correctly in a normal row, but `Picker`/`Menu` force their
    /// item icons to monochrome template rendering regardless of
    /// `.foregroundStyle` — baking the color into the image bytes with a
    /// `UIImage` and marking it "original" is what actually survives that.
    var pickerIcon: Image {
        let uiImage = UIImage(systemName: "circle.fill")?
            .withTintColor(UIColor(swiftUIColor), renderingMode: .alwaysOriginal)
        return Image(uiImage: uiImage ?? UIImage())
    }
}

extension FavoriteTagColor {
    var localizedTitle: String {
        switch self {
        case .red:
            L10n.string("color.red")
        case .orange:
            L10n.string("color.orange")
        case .yellow:
            L10n.string("color.yellow")
        case .green:
            L10n.string("color.green")
        case .blue:
            L10n.string("color.blue")
        case .purple:
            L10n.string("color.purple")
        case .pink:
            L10n.string("color.pink")
        case .gray:
            L10n.string("color.gray")
        }
    }
}

extension [FavoriteCategory] {
    /// Categories in the user's manual order with a stable ID tiebreaker.
    var manualOrderSorted: [FavoriteCategory] {
        sorted { lhs, rhs in
            if lhs.manualOrder != rhs.manualOrder {
                return lhs.manualOrder < rhs.manualOrder
            }
            return lhs.id < rhs.id
        }
    }
}

extension FavoriteRemoteSyncPhase {
    var displayTitle: String {
        switch self {
        case .queued:
            L10n.string("favorites.sync.phase.queued")
        case .preparing:
            L10n.string("favorites.sync.phase.preparing")
        case .fetching:
            L10n.string("favorites.sync.phase.fetching")
        case .importing:
            L10n.string("favorites.sync.phase.importing")
        case .uploading:
            L10n.string("favorites.sync.phase.uploading")
        case .reconciling:
            L10n.string("favorites.sync.phase.reconciling")
        case .completed:
            L10n.string("favorites.sync.phase.completed")
        case .failed:
            L10n.string("favorites.sync.phase.failed")
        case .interrupted:
            L10n.string("favorites.sync.phase.interrupted")
        }
    }
}

extension FavoriteRemoteSyncLogEntry {
    var displayText: String {
        switch self {
        case let .started(categoryName):
            L10n.string("favorites.sync.log.started", categoryName)
        case let .fetchedPage(page, totalPages, accumulatedCount):
            L10n.string("favorites.sync.log.fetched_page", page, totalPages, accumulatedCount)
        case let .importingItem(index, total, title):
            L10n.string("favorites.sync.log.importing_item", index, total, title)
        case let .skippedSyncedItems(path, count):
            L10n.string("favorites.sync.log.skipped_synced", count, path)
        case let .uploading(targetCount):
            L10n.string("favorites.sync.log.uploading", targetCount)
        case let .uploadedItem(index, total, title):
            L10n.string("favorites.sync.log.uploaded_item", index, total, title)
        case .reconciling:
            L10n.string("favorites.sync.log.reconciling")
        case let .completed(importedCount, uploadedCount):
            L10n.string("favorites.sync.log.completed", importedCount, uploadedCount)
        case .failed:
            L10n.string("favorites.sync.log.failed")
        case .interrupted:
            L10n.string("favorites.sync.log.interrupted")
        case .taskLost:
            L10n.string("favorites.sync.log.task_lost")
        }
    }
}

extension FavoriteRemoteSyncWarning {
    var displayText: String {
        switch self {
        case .interruptedByUser:
            L10n.string("favorites.sync.warning.interrupted_by_user")
        case .interrupted:
            L10n.string("favorites.sync.warning.interrupted")
        case .taskLost:
            L10n.string("favorites.sync.warning.task_lost")
        case .backgroundExpired:
            L10n.string("favorites.sync.warning.background_expired")
        case .backgroundUnavailable:
            L10n.string("favorites.sync.warning.background_unavailable")
        case .remotePageCountChanged:
            L10n.string("favorites.sync.warning.page_count_changed")
        case let .duplicateRemoteEntry(title):
            L10n.string("favorites.sync.warning.duplicate_remote_entry", title)
        case let .importFailedItem(title, reason):
            L10n.string("favorites.sync.warning.import_failed_item", title, reason)
        case let .uploadFailedItem(title, reason):
            L10n.string("favorites.sync.warning.upload_failed_item", title, reason)
        case let .reconcileFailed(reason):
            L10n.string("favorites.sync.warning.reconcile_failed", reason)
        case let .remoteFavoritesEmptyBeforeBulkUpload(count):
            L10n.string("favorites.sync.warning.remote_favorites_empty_before_upload", count)
        case let .importedIntoExistingMangaDirectory(title, cleanBookName):
            L10n.string("favorites.sync.warning.imported_into_existing_manga_directory", title, cleanBookName)
        }
    }
}

extension FavoriteUpdateRunProgress {
    var displayText: String {
        switch self {
        case let .loadedTargets(count):
            L10n.string("favorites.updates.loaded_targets", count)
        case let .checking(index, total, title):
            L10n.string("favorites.updates.checking_item", index, total, title)
        }
    }
}

extension FavoriteUpdateSummary {
    var displayText: String {
        switch self {
        case let .newReplies(count):
            L10n.string("favorites.updates.summary.replies", count)
        case let .newPages(count):
            L10n.string("favorites.updates.summary.pages", count)
        case let .newChapters(count):
            L10n.string("favorites.updates.summary.new_chapters", count)
        case .changed:
            L10n.string("favorites.updates.summary.changed")
        }
    }
}
