import SwiftUI
import YamiboXCore

struct OfflineCacheStorageSummary: View {
    let rows: [OfflineCacheManagementRow]
    var isSelecting = false
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                L10n.string(isSelecting ? "settings.offline_cache.selected_storage" : "settings.offline_cache.storage_used"),
                systemImage: isSelecting ? "checkmark.circle" : "internaldrive"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)

            Text(ByteCountFormatter.string(fromByteCount: Int64(rows.reduce(0) { $0 + $1.byteCount }), countStyle: .file))
                .font(.largeTitle.weight(.semibold).monospacedDigit())
                .foregroundStyle(appTheme.controlAccent)
                .fixedSize(horizontal: false, vertical: true)

            OfflineCacheStatusSummary(
                cachedCount: rows.reduce(0) { $0 + $1.cachedCount },
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
struct OfflineCacheStatusSummary: View {
    let cachedCount: Int
    let pendingCount: Int
    let failedCount: Int

    var body: some View {
        Text(summary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        var pieces = [L10n.string("settings.offline_cache.cached_count_format", cachedCount)]
        if pendingCount > 0 {
            pieces.append(L10n.string("settings.offline_cache.pending_count_format", pendingCount))
        }
        if failedCount > 0 {
            pieces.append(L10n.string("settings.offline_cache.failed_count_format", failedCount))
        }
        return pieces.joined(separator: " · ")
    }
}
