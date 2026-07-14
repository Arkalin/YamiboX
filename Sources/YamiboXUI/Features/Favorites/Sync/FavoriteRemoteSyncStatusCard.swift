import SwiftUI
import YamiboXCore

/// Compact remote sync status card pinned above the favorites list.
struct FavoriteRemoteSyncStatusCard: View {
    let snapshot: FavoriteRemoteSyncSnapshot
    let onOpen: () -> Void
    let onResume: () -> Void
    let onInterrupt: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusImageName)
                    .foregroundStyle(statusColor)
                    .font(.title3.weight(.semibold))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.phase.displayTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(action: onHide) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .expandedHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("favorites.sync.hide_card"))
            }

            ProgressView(value: progressValue)
                .opacity(snapshot.status == .running ? 1 : 0.65)

            HStack(spacing: 8) {
                Button(action: onOpen) {
                    Label(L10n.string("favorites.sync.progress.open"), systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)

                if snapshot.status == .running {
                    Button(role: .destructive, action: onInterrupt) {
                        Label(L10n.string("favorites.sync.interrupt"), systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: onResume) {
                        Label(L10n.string("favorites.sync.resume"), systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Coarse overall progress across the five phases: fetch 5–35%,
    /// import 35–75%, upload 75–95%, reconcile 95%.
    private var progressValue: Double {
        func fraction(_ completed: Int, _ total: Int) -> Double {
            total > 0 ? min(1, Double(completed) / Double(total)) : 0
        }
        switch snapshot.phase {
        case .queued, .preparing:
            return 0.05
        case .fetching:
            let pages = fraction(snapshot.currentPage ?? 0, snapshot.totalPages ?? 0)
            return 0.05 + 0.3 * pages
        case .importing:
            let handled = snapshot.importedCount + snapshot.skippedCount + snapshot.failedCount
            return 0.35 + 0.4 * fraction(handled, snapshot.scannedCount)
        case .uploading:
            return 0.75 + 0.2 * fraction(snapshot.uploadedCount, snapshot.uploadTargetCount)
        case .reconciling:
            return 0.95
        case .completed, .failed, .interrupted:
            return 1
        }
    }

    private var statusTitle: String {
        switch snapshot.status {
        case .running:
            L10n.string("favorites.sync.status.running")
        case .completed:
            L10n.string("favorites.sync.status.completed")
        case .failed:
            L10n.string("favorites.sync.status.failed")
        case .interrupted:
            L10n.string("favorites.sync.status.interrupted")
        }
    }

    private var statusImageName: String {
        switch snapshot.status {
        case .running:
            "arrow.triangle.2.circlepath"
        case .completed:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .interrupted:
            "pause.circle"
        }
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .running:
            .accentColor
        case .completed:
            .green
        case .failed:
            .red
        case .interrupted:
            .orange
        }
    }
}
