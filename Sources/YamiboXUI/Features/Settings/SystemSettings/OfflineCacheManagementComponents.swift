import SwiftUI
import YamiboXCore

/// Drill-down detail of one cached work, pushed from the management list
/// (hierarchy navigation, not a self-contained modal task).
struct OfflineCacheManagementGroupScreen: View {
    let viewModel: OfflineCacheManagementViewModel
    let groupID: OfflineCacheGroupID
    @Environment(\.dismiss) private var dismiss

    private var row: OfflineCacheManagementRow? {
        viewModel.offlineCacheManagementRow(id: groupID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = viewModel.loadFailure {
                    LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                        Task { await viewModel.refreshOfflineCacheManagement() }
                    }
                }
                if let row {
                    OfflineCacheStorageSummary(rows: [row])
                    HStack {
                        Text(L10n.string("settings.offline_cache.contents"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            viewModel.requestOfflineCacheGroupDeletion(id: row.id)
                        } label: {
                            Label(L10n.string("settings.offline_cache.delete_group"), systemImage: "trash")
                                .font(.subheadline)
                                .frame(minHeight: 44)
                        }
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(row.entries) { entry in
                            OfflineCacheManagementEntryRowView(entry: entry) {
                                viewModel.requestOfflineCacheEntryDeletion(id: entry.id)
                            }
                        }
                    }
                } else if viewModel.loadFailure == nil {
                    OfflineCacheManagementEmptyState()
                }
            }
            .padding(16)
            .disabled(viewModel.activeAction == .clearingOfflineCache)
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
            if (viewModel.activeAction == .loading && row == nil) || viewModel.activeAction == .clearingOfflineCache {
                ProgressView(L10n.string(viewModel.activeAction == .clearingOfflineCache ? "common.deleting" : "common.loading"))
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .offlineCacheManagementAlert(viewModel: viewModel)
    }

    private func dismissIfGroupMissing() {
        if row == nil, viewModel.loadFailure == nil {
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
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelecting ? (isSelected ? "checkmark.circle.fill" : "circle")
                : (row.readerKind == .manga ? "photo.on.rectangle.angled" : "text.book.closed.fill"))
                .font(.title3)
                .foregroundStyle(dimming.emphasis(appTheme.controlAccent))
                .frame(width: 40, height: 48)
                .background(dimming.emphasis(appTheme.controlAccent).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(dimming.titleColor)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

                Text(row.byteCountLabel)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(dimming.emphasis(appTheme.controlAccent))

                OfflineCacheStatusSummary(cachedCount: row.cachedCount, pendingCount: row.pendingCount, failedCount: row.failedCount)
                    .font(.caption)
                    .foregroundStyle(dimming.secondaryColor)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .padding(.top, 6)
                .opacity(isSelecting ? 0 : 1)
                .accessibilityHidden(isSelecting)
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected, onTap: rowAction)
        .contextMenu {
            if !isSelecting {
                Button(role: .destructive, action: delete) {
                    Label(L10n.string("settings.offline_cache.delete_cache"), systemImage: "trash")
                }
            }
        }
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
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.id.readerKind == .manga ? "photo" : "doc.text")
                    .foregroundStyle(appTheme.controlAccent)
                    .accessibilityHidden(true)
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Label(stateTitle, systemImage: stateImage)
                        .foregroundStyle(stateColor)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    Text(byteCountLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(stateTitle, systemImage: stateImage).foregroundStyle(stateColor)
                    Text(byteCountLabel).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Button(role: .destructive, action: delete) {
                Label(L10n.string("settings.offline_cache.delete_cache"), systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .cardRowChrome()
    }

    private var stateColor: Color {
        switch entry.state {
        case .failed: .red
        case .queued, .paused: .secondary
        case .cached, .running: appTheme.controlAccent
        }
    }

    private var stateImage: String {
        switch entry.state {
        case .cached: "checkmark.circle.fill"
        case .queued: "clock"
        case .running: "arrow.down.circle"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle"
        }
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
    let viewModel: OfflineCacheManagementViewModel

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
        ContentUnavailableView {
            Label(L10n.string("settings.offline_cache.empty_title"), systemImage: "internaldrive")
        } description: {
            Text(L10n.string("settings.offline_cache.empty_message"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

extension View {
    func offlineCacheManagementAlert(viewModel: OfflineCacheManagementViewModel) -> some View {
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
