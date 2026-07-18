import SwiftUI
import YamiboXCore

struct MangaDirectoryManagementRowView: View {
    let row: MangaDirectoryManagementRow
    let isSelecting: Bool
    let isSelected: Bool
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .foregroundStyle(dimming.emphasis(.indigo))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .foregroundStyle(dimming.titleColor)
                    .lineLimit(2)

                Text(row.summaryText)
                    .font(.caption)
                    .foregroundStyle(dimming.secondaryColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected) {
            // No per-directory drill-down exists here, so a tap outside
            // selection mode is a no-op — only the "select" toolbar button
            // and swipe-to-delete are live until selection mode is entered.
            if isSelecting {
                select()
            }
        }
        .deleteSwipeAction(perform: delete)
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }
}

struct MangaDirectoryManagementSelectAllButton: View {
    let viewModel: MangaDirectoryManagementViewModel

    var body: some View {
        SelectAllToolbarButton(
            isSelectionComplete: viewModel.isMangaDirectoryManagementSelectionComplete,
            isDisabled: viewModel.mangaDirectoryManagementIsEmpty
        ) {
            viewModel.toggleAllMangaDirectoryManagementRows()
        }
    }
}

struct MangaDirectoryManagementEmptyState: View {
    var body: some View {
        GroupedEmptyStateCard(
            title: L10n.string("settings.manga_directory.empty_title"),
            message: L10n.string("settings.manga_directory.empty_message")
        )
    }
}

extension View {
    func mangaDirectoryManagementAlert(viewModel: MangaDirectoryManagementViewModel) -> some View {
        destructiveConfirmationAlert(
            item: Binding(
                get: { viewModel.pendingMangaDirectoryManagementConfirmation },
                set: { pending in
                    if pending == nil {
                        Task { @MainActor in
                            viewModel.cancelMangaDirectoryManagementConfirmation()
                        }
                    }
                }
            ),
            title: \.title,
            // "清除", not "common.delete" ("删除") — the dialog's own
            // title/message are framed as a cleanup ("清理"), and the
            // confirm button should read as the same action, not a
            // more destructive-sounding synonym.
            actionTitle: { _ in L10n.string("common.clear") },
            message: \.message
        ) { confirmation in
            Task {
                _ = await viewModel.confirmMangaDirectoryManagementDeletion(confirmation)
            }
        }
    }
}
