import SwiftUI
import YamiboXCore

struct DownloadStorageSummary: View {
    let rows: [DownloadManagementRow]
    var isSelecting = false
    var showsEntryCount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                L10n.string(isSelecting ? "settings.download.selected_storage" : "settings.download.storage_used"),
                systemImage: isSelecting ? "checkmark.circle" : "internaldrive"
            )
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            if isSelecting {
                Text(L10n.string("settings.download.selected_count", rows.count))
                    .font(.headline)
            } else {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(rows.reduce(0) { $0 + $1.byteCount }), countStyle: .file)
                )
                .font(.title2.weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
                Text(L10n.string(
                    showsEntryCount ? "downloads.local_entry_count" : "downloads.local_work_count",
                    showsEntryCount ? rows.reduce(0) { $0 + $1.entries.count } : rows.count
                ))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// Keep state counts readable even when a work has both saved and unfinished entries.
struct DownloadStatusSummary: View {
    let downloadedCount: Int
    let pendingCount: Int
    let failedCount: Int

    var body: some View {
        Text(summary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        var pieces = [L10n.string("settings.download.downloaded_count_format", downloadedCount)]
        if pendingCount > 0 {
            pieces.append(L10n.string("settings.download.pending_count_format", pendingCount))
        }
        if failedCount > 0 {
            pieces.append(L10n.string("settings.download.failed_count_format", failedCount))
        }
        return pieces.joined(separator: " · ")
    }
}
