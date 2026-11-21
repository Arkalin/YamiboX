import SwiftUI
import YamiboXCore

struct MangaDirectoryManagementRowView: View {
    let row: MangaDirectoryManagementRow
    let isSelecting: Bool
    let isSelected: Bool
    let select: () -> Void
    let delete: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .foregroundStyle(dimming.emphasis(appTheme.controlAccent))
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
            actionTitle: { _ in L10n.string("common.clear") },
            message: { $0.message + "\n\n" + viewModel.deletionNotice }
        ) { confirmation in
            Task {
                _ = await viewModel.confirmMangaDirectoryManagementDeletion(confirmation)
            }
        }
    }
}
