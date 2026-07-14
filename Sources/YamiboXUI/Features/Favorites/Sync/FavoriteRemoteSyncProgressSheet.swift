import SwiftUI
import YamiboXCore

/// Detailed progress sheet for a remote favorite sync run. Also used from
/// system settings, which is why the actions are optional closures.
struct FavoriteRemoteSyncProgressSheet: View {
    let snapshot: FavoriteRemoteSyncSnapshot?
    var onResume: (() async -> String?)? = nil
    var onInterrupt: (() async -> Void)? = nil
    var onHide: (() async -> Void)? = nil
    /// False when pushed onto an existing stack (the favorites page), which
    /// already gets a back button from `NavigationStack` for free — showing
    /// this too would duplicate it. True for the system-settings sheet,
    /// which is the root of its own stack and has no other way to dismiss.
    var showsCloseButton: Bool = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let snapshot {
                Section {
                    FavoriteRemoteSyncSummary(snapshot: snapshot)
                }

                Section(L10n.string("favorites.sync.progress.metrics")) {
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.target"), value: snapshot.targetCategoryName)
                    if let currentPage = snapshot.currentPage, let totalPages = snapshot.totalPages {
                        FavoriteRemoteSyncMetricRow(
                            title: L10n.string("favorites.sync.progress.pages"),
                            value: "\(currentPage)/\(totalPages)"
                        )
                    }
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.scanned"), value: "\(snapshot.scannedCount)")
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.imported"), value: "\(snapshot.importedCount)")
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.skipped"), value: "\(snapshot.skippedCount)")
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.upload_targets"), value: "\(snapshot.uploadTargetCount)")
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.uploaded"), value: "\(snapshot.uploadedCount)")
                    FavoriteRemoteSyncMetricRow(title: L10n.string("favorites.sync.progress.failed"), value: "\(snapshot.failedCount)")
                }

                FavoriteRemoteSyncMessageSection(
                    title: L10n.string("favorites.sync.progress.logs"),
                    messages: snapshot.logEntries.map(\.displayText),
                    fallback: L10n.string("favorites.sync.progress.no_logs")
                )
                FavoriteRemoteSyncMessageSection(
                    title: L10n.string("favorites.sync.progress.warnings"),
                    messages: snapshot.warnings.map(\.displayText),
                    fallback: L10n.string("favorites.sync.progress.no_warnings")
                )
                FavoriteRemoteSyncMessageSection(
                    title: L10n.string("favorites.sync.progress.errors"),
                    messages: snapshot.errorMessages,
                    fallback: L10n.string("favorites.sync.progress.no_errors")
                )
            } else {
                ContentUnavailableView(L10n.string("favorites.sync.progress.empty"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .navigationTitle(L10n.string("favorites.sync.progress.title"))
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close")) {
                        dismiss()
                    }
                }
            }
            if let snapshot, hasActions {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if snapshot.status == .running, let onInterrupt {
                            Button(role: .destructive) {
                                Task { await onInterrupt() }
                            } label: {
                                Label(L10n.string("favorites.sync.interrupt"), systemImage: "stop.circle")
                            }
                        } else if let onResume {
                            Button {
                                Task { _ = await onResume() }
                            } label: {
                                Label(L10n.string("favorites.sync.resume"), systemImage: "play.circle")
                            }
                        }
                        if let onHide {
                            Button {
                                Task {
                                    await onHide()
                                    dismiss()
                                }
                            } label: {
                                Label(L10n.string("favorites.sync.hide_card"), systemImage: "eye.slash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var hasActions: Bool {
        onResume != nil || onInterrupt != nil || onHide != nil
    }
}

private struct FavoriteRemoteSyncSummary: View {
    let snapshot: FavoriteRemoteSyncSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusTitle)
                    .font(.headline)
                Spacer()
                Text(snapshot.updatedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(snapshot.phase.displayTitle)
                .foregroundStyle(.secondary)
            if let progress = phaseProgress {
                ProgressView(value: progress.completed, total: progress.total)
            }
        }
        .padding(.vertical, 4)
    }

    /// Progress of the currently running phase; nil when the phase has no
    /// meaningful denominator yet.
    private var phaseProgress: (completed: Double, total: Double)? {
        switch snapshot.phase {
        case .fetching:
            guard let currentPage = snapshot.currentPage, let totalPages = snapshot.totalPages else { return nil }
            return (Double(currentPage), Double(max(totalPages, 1)))
        case .importing:
            let handled = snapshot.importedCount + snapshot.skippedCount + snapshot.failedCount
            return (Double(handled), Double(max(snapshot.scannedCount, 1)))
        case .uploading, .reconciling:
            guard snapshot.uploadTargetCount > 0 else { return nil }
            return (Double(snapshot.uploadedCount), Double(snapshot.uploadTargetCount))
        case .queued, .preparing, .completed, .failed, .interrupted:
            return nil
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
}

private struct FavoriteRemoteSyncMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

/// Log/warning/error block rendered as one scrollable text area (Android
/// SyncMessageBlock parity), not a list of rows.
private struct FavoriteRemoteSyncMessageSection: View {
    let title: String
    let messages: [String]
    let fallback: String

    /// Matches Android SyncMessageBlock's default `maxHeight` (180dp): the
    /// block scrolls within this bounded area as lines accumulate instead of
    /// growing the whole sheet. `heightIn(max:)`-style behavior — short
    /// content still shrinks to its natural height.
    private let maxBlockHeight: CGFloat = 180

    var body: some View {
        Section(title) {
            if messages.isEmpty {
                Text(fallback)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(messages.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: maxBlockHeight)
            }
        }
    }
}
