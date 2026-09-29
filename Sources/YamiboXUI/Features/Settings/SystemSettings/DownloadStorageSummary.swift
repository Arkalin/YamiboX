import SwiftUI
import YamiboXCore

struct DownloadStorageSummary: View {
    let rows: [DownloadManagementRow]
    var isSelecting = false
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                L10n.string(isSelecting ? "settings.download.selected_storage" : "settings.download.storage_used"),
                systemImage: isSelecting ? "checkmark.circle" : "internaldrive"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            Text(ByteCountFormatter.string(fromByteCount: Int64(rows.reduce(0) { $0 + $1.byteCount }), countStyle: .file))
                .font(.largeTitle.weight(.semibold).monospacedDigit())
                .foregroundStyle(appTheme.controlAccent)
                .fixedSize(horizontal: false, vertical: true)

            DownloadStatusSummary(
                downloadedCount: rows.reduce(0) { $0 + $1.downloadedCount },
                pendingCount: rows.reduce(0) { $0 + $1.pendingCount },
                failedCount: rows.reduce(0) { $0 + $1.failedCount }
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(YamiboColors.SystemSurface.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
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
