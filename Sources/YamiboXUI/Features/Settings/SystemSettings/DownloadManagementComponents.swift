import SwiftUI
import YamiboXCore

/// Drill-down detail of one downloaded work, pushed from the management list
/// (hierarchy navigation, not a self-contained modal task).
struct DownloadManagementGroupScreen: View {
    let viewModel: DownloadManagementViewModel
    let groupID: DownloadGroupID
    @Environment(\.dismiss) private var dismiss

    private var row: DownloadManagementRow? {
        viewModel.downloadManagementRow(id: groupID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = viewModel.loadFailure {
                    LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                        Task { await viewModel.refreshDownloadManagement() }
                    }
                }
                if let row {
                    DownloadStorageSummary(rows: [row])
                    HStack {
                        Text(L10n.string("settings.download.contents"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            viewModel.requestDownloadGroupDeletion(id: row.id)
                        } label: {
                            Label(L10n.string("settings.download.delete_group"), systemImage: "trash")
                                .font(.subheadline)
                                .frame(minHeight: 44)
                        }
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(row.entries) { entry in
                            DownloadManagementEntryRowView(entry: entry) {
                                viewModel.requestDownloadEntryDeletion(id: entry.id)
                            }
                        }
                    }
                } else if viewModel.loadFailure == nil {
                    DownloadManagementEmptyState()
                }
            }
            .padding(16)
            .disabled(viewModel.activeAction == .clearingDownload)
        }
        .background(YamiboColors.SystemSurface.groupedBackground)
        .navigationTitle(row?.title ?? L10n.string("settings.download.title"))
        .task {
            await viewModel.refreshDownloadManagement()
            dismissIfGroupMissing()
        }
        .refreshable {
            await viewModel.refreshDownloadManagement()
            dismissIfGroupMissing()
        }
        .onChange(of: viewModel.downloadManagementRows) {
            dismissIfGroupMissing()
        }
        .overlay {
            if (viewModel.activeAction == .loading && row == nil) || viewModel.activeAction == .clearingDownload {
                ProgressView(L10n.string(viewModel.activeAction == .clearingDownload ? "common.deleting" : "common.loading"))
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .downloadManagementAlert(viewModel: viewModel)
    }

    private func dismissIfGroupMissing() {
        if row == nil, viewModel.loadFailure == nil {
            dismiss()
        }
    }
}

struct DownloadManagementGroupRowView: View {
    let row: DownloadManagementRow
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

                DownloadStatusSummary(downloadedCount: row.downloadedCount, pendingCount: row.pendingCount, failedCount: row.failedCount)
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
                    Label(L10n.string("settings.download.delete_download"), systemImage: "trash")
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

private struct DownloadManagementEntryRowView: View {
    let entry: DownloadManagementEntry
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
                Label(L10n.string("settings.download.delete_download"), systemImage: "trash")
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
        case .downloaded, .running: appTheme.controlAccent
        }
    }

    private var stateImage: String {
        switch entry.state {
        case .downloaded: "checkmark.circle.fill"
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
        case .downloaded:
            L10n.string("settings.download.state.downloaded")
        case .queued:
            L10n.string("settings.download.state.queued")
        case .running:
            L10n.string("settings.download.state.running")
        case .paused:
            L10n.string("settings.download.state.paused")
        case .failed:
            L10n.string("settings.download.state.failed")
        }
    }
}

struct DownloadManagementSelectAllButton: View {
    let viewModel: DownloadManagementViewModel

    var body: some View {
        SelectAllToolbarButton(
            isSelectionComplete: viewModel.isDownloadManagementSelectionComplete,
            isDisabled: viewModel.downloadManagementIsEmpty
        ) {
            viewModel.toggleAllDownloadManagementRows()
        }
    }
}

/// Builds the selection-mode bottom bar's single "delete selected" action —
/// rendering is delegated to the shared `SelectionBottomToolbar`.
enum DownloadManagementSelectionActions {
    static func delete(
        actionState: DownloadManagementSelectionActionState,
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
                    "settings.download.delete_selected_format",
                    actionState.selectedGroupCount
                ),
                action: onDelete
            )
        ]
    }
}

struct DownloadManagementEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("settings.download.empty_title"), systemImage: "internaldrive")
        } description: {
            Text(L10n.string("settings.download.empty_message"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

extension View {
    func downloadManagementAlert(viewModel: DownloadManagementViewModel) -> some View {
        destructiveConfirmationAlert(
            item: Binding(
                get: { viewModel.pendingDownloadManagementConfirmation },
                set: { pending in
                    if pending == nil {
                        Task { @MainActor in
                            viewModel.cancelDownloadManagementConfirmation()
                        }
                    }
                }
            ),
            title: \.title,
            actionTitle: { _ in L10n.string("common.delete") },
            message: \.message
        ) { confirmation in
            Task {
                _ = await viewModel.confirmDownloadManagementDeletion(confirmation)
            }
        }
    }
}
