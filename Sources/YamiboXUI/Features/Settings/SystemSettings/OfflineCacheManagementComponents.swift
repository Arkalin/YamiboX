import SwiftUI
import YamiboXCore

/// Drill-down detail of one cached work, pushed from the management list
/// (hierarchy navigation, not a self-contained modal task).
struct OfflineCacheManagementGroupScreen: View {
    @ObservedObject var viewModel: SystemSettingsViewModel
    let groupID: OfflineCacheGroupID
    @Environment(\.dismiss) private var dismiss

    private var row: OfflineCacheManagementRow? {
        viewModel.offlineCacheManagementRow(id: groupID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let row {
                    ForEach(row.entries) { entry in
                        OfflineCacheManagementEntryRowView(entry: entry) {
                            viewModel.requestOfflineCacheEntryDeletion(id: entry.id)
                        }
                    }
                } else {
                    OfflineCacheManagementEmptyState()
                }
            }
            .padding(16)
        }
        .background(YamiboColors.SystemSurface.groupedBackground)
        .navigationTitle(row?.title ?? L10n.string("settings.offline_cache.title"))
        .task {
            await viewModel.refreshOfflineCacheManagement()
            dismissIfGroupMissing()
        }
        .refreshable {
            await viewModel.refreshOfflineCacheManagement()
            dismissIfGroupMissing()
        }
        .onChange(of: viewModel.offlineCacheManagementRows) {
            dismissIfGroupMissing()
        }
        .overlay {
            if viewModel.activeAction == .loading || viewModel.activeAction == .clearingOfflineCache {
                ProgressView()
            }
        }
        .offlineCacheManagementAlert(viewModel: viewModel)
    }

    private func dismissIfGroupMissing() {
        if row == nil {
            dismiss()
        }
    }
}

struct OfflineCacheManagementGroupRowView: View {
    let row: OfflineCacheManagementRow
    let isSelecting: Bool
    let isSelected: Bool
    let open: () -> Void
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.readerKind == .manga ? "photo.on.rectangle.angled" : "text.book.closed.fill")
                .foregroundStyle(dimming.emphasis(.indigo))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .foregroundStyle(dimming.titleColor)
                    .lineLimit(2)

                Text(row.summaryText)
                    .font(.caption)
                    .foregroundStyle(dimming.secondaryColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .opacity(isSelecting ? 0 : 1)
                .accessibilityHidden(isSelecting)
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected, onTap: rowAction)
        .deleteSwipeAction(perform: delete)
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private func rowAction() {
        if isSelecting {
            select()
        } else {
            open()
        }
    }
}

private struct OfflineCacheManagementEntryRowView: View {
    let entry: OfflineCacheManagementEntry
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.image")
                .foregroundStyle(entry.state == .failed ? Color.red : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(entrySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
        }
        .cardRowChrome()
        .deleteSwipeAction(perform: delete)
    }

    private var entrySummary: String {
        [
            stateTitle,
            byteCountLabel
        ].joined(separator: " · ")
    }

    private var byteCountLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(max(0, entry.byteCount)))
    }

    private var stateTitle: String {
        switch entry.state {
        case .cached:
            L10n.string("settings.offline_cache.state.cached")
        case .queued:
            L10n.string("settings.offline_cache.state.queued")
        case .running:
            L10n.string("settings.offline_cache.state.running")
        case .paused:
            L10n.string("settings.offline_cache.state.paused")
        case .failed:
            L10n.string("settings.offline_cache.state.failed")
        }
    }
}

struct OfflineCacheManagementSelectAllButton: View {
    let viewModel: SystemSettingsViewModel

    var body: some View {
        SelectAllToolbarButton(
            isSelectionComplete: viewModel.isOfflineCacheManagementSelectionComplete,
            isDisabled: viewModel.offlineCacheManagementIsEmpty
        ) {
            viewModel.toggleAllOfflineCacheManagementRows()
        }
    }
}

/// Builds the selection-mode bottom bar's single "delete selected" action —
/// rendering is delegated to the shared `SelectionBottomToolbar`.
enum OfflineCacheManagementSelectionActions {
    static func delete(
        actionState: OfflineCacheManagementSelectionActionState,
        onDelete: @escaping () -> Void
    ) -> [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "delete",
                title: L10n.string("common.delete"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: actionState.canDelete,
                accessibilityLabel: L10n.string(
                    "settings.offline_cache.delete_selected_format",
                    actionState.selectedGroupCount
                ),
                action: onDelete
            )
        ]
    }
}

struct OfflineCacheManagementEmptyState: View {
    var body: some View {
        GroupedEmptyStateCard(
            title: L10n.string("settings.offline_cache.empty_title"),
            message: L10n.string("settings.offline_cache.empty_message")
        )
    }
}

extension View {
    func offlineCacheManagementAlert(viewModel: SystemSettingsViewModel) -> some View {
        destructiveConfirmationAlert(
            item: Binding(
                get: { viewModel.pendingOfflineCacheManagementConfirmation },
                set: { pending in
                    if pending == nil {
                        Task { @MainActor in
                            viewModel.cancelOfflineCacheManagementConfirmation()
                        }
                    }
                }
            ),
            title: \.title,
            actionTitle: { _ in L10n.string("common.delete") },
            message: \.message
        ) { confirmation in
            Task {
                _ = await viewModel.confirmOfflineCacheManagementDeletion(confirmation)
            }
        }
    }
}
