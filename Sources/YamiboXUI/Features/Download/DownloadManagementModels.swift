import Foundation
import YamiboXCore

struct DownloadManagementRow: Hashable, Identifiable {
    var id: DownloadGroupID
    var readerKind: DownloadReaderKind
    var title: String
    var byteCount: Int
    var downloadedCount: Int
    var pendingCount: Int
    var failedCount: Int
    var entries: [DownloadManagementEntry]

    init(group: DownloadManagementGroup) {
        id = group.id
        readerKind = group.id.readerKind
        title = group.title
        byteCount = group.byteCount
        entries = group.entries.filter { $0.state == .downloaded || $0.byteCount > 0 }
        downloadedCount = entries.filter { $0.state == .downloaded }.count
        pendingCount = entries.filter { [.queued, .running, .paused].contains($0.state) }.count
        failedCount = entries.filter { $0.state == .failed }.count
    }

    var byteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(max(0, byteCount)))
    }

    var summaryText: String {
        var pieces = [
            L10n.string("settings.download.entry_count_format", entries.count),
            byteCountLabel,
        ]
        if pendingCount > 0 {
            pieces.append(L10n.string("settings.download.pending_count_format", pendingCount))
        }
        if failedCount > 0 {
            pieces.append(L10n.string("settings.download.failed_count_format", failedCount))
        }
        return pieces.joined(separator: " · ")
    }
}

struct DownloadManagementSelectionActionState: Equatable {
    let selectedGroupCount: Int
    let canDelete: Bool
}

struct DownloadManagementConfirmation: Identifiable, Equatable {
    var groupIDs: [DownloadGroupID]
    var entryIDs: [DownloadEntryID]
    var titles: [String]

    var id: String {
        let groupPart = groupIDs.map { "\($0.readerKind.rawValue):\($0.ownerKey)" }.joined(separator: "|")
        let entryPart = entryIDs.map {
            "\($0.readerKind.rawValue):\($0.ownerKey):\($0.entryKey)"
        }.joined(separator: "|")
        return [groupPart, entryPart].filter { !$0.isEmpty }.joined(separator: "#")
    }

    init(groupIDs: [DownloadGroupID] = [], entryIDs: [DownloadEntryID] = [], titles: [String]) {
        self.groupIDs = groupIDs
        self.entryIDs = entryIDs
        self.titles = titles
    }

    var title: String {
        if isEntryDeletion {
            return L10n.string("settings.download.confirm_entry_title")
        }
        if groupIDs.count == 1 {
            return L10n.string("settings.download.confirm_single_title")
        }
        return L10n.string("settings.download.confirm_batch_title")
    }

    var message: String {
        if isEntryDeletion {
            if let firstTitle = titles.first, entryIDs.count == 1 {
                return L10n.string("settings.download.confirm_entry_message", firstTitle)
            }
            return L10n.string("settings.download.confirm_entry_batch_message", entryIDs.count)
        }
        if let firstTitle = titles.first, groupIDs.count == 1 {
            return L10n.string("settings.download.confirm_single_message", firstTitle)
        }
        return L10n.string("settings.download.confirm_batch_message", groupIDs.count)
    }

    private var isEntryDeletion: Bool {
        !entryIDs.isEmpty
    }
}
