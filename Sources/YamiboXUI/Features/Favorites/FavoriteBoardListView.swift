import SwiftUI
import YamiboXCore

/// Board-favorite management page, pushed from the favorites screen's
/// overflow menu. Purely remote: the list mirrors the forum account's
/// favorited boards and deletes go straight to the forum, with no local
/// bookkeeping.
struct FavoriteBoardListView: View {
    @State private var model: FavoriteBoardListViewModel
    @State private var pendingDeletion: BoardFavorite?

    let onOpenBoard: (BoardFavorite) -> Void

    init(model: FavoriteBoardListViewModel, onOpenBoard: @escaping (BoardFavorite) -> Void) {
        _model = State(wrappedValue: model)
        self.onOpenBoard = onOpenBoard
    }

    var body: some View {
        content
            .navigationTitle(L10n.string("favorites.boards.title"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await model.load()
            }
            .alert(L10n.string("common.operation_failed"), isPresented: actionErrorBinding) {
                Button(L10n.string("common.ok")) {
                    model.actionErrorMessage = nil
                }
            } message: {
                Text(model.actionErrorMessage ?? "")
            }
            .destructiveConfirmationAlert(
                item: $pendingDeletion,
                title: { _ in L10n.string("favorites.boards.delete_confirm_title") },
                actionTitle: { _ in L10n.string("common.delete") },
                message: { board in L10n.string("favorites.boards.delete_confirm_message", board.title) }
            ) { board in
                Task { await model.delete(board) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = model.errorMessage, model.boards == nil {
            LoadFailureView(
                title: L10n.string("favorites.boards.load_failed"),
                systemImage: "wifi.exclamationmark",
                message: errorMessage
            ) {
                Task { await model.refresh() }
            }
        } else if let boards = model.boards {
            List {
                ForEach(boards) { board in
                    row(board)
                }
            }
            .overlay {
                if boards.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("favorites.boards.empty"), systemImage: "square.grid.2x2")
                    } description: {
                        Text(L10n.string("favorites.boards.empty_hint"))
                    }
                }
            }
            .refreshable {
                await model.refresh()
            }
        } else {
            ProgressView(L10n.string("common.loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ board: BoardFavorite) -> some View {
        Button {
            onOpenBoard(board)
        } label: {
            HStack {
                Text(board.title)
                    .foregroundStyle(.primary)
                Spacer()
                if model.isDeleting(board) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(model.isDeleting(board))
        .deleteSwipeAction(allowsFullSwipe: false) {
            pendingDeletion = board
        }
        .contextMenu {
            Button {
                onOpenBoard(board)
            } label: {
                Label(L10n.string("favorites.boards.open"), systemImage: "arrow.up.right.square")
            }
            Button(role: .destructive) {
                pendingDeletion = board
            } label: {
                Label(L10n.string("common.delete"), systemImage: "trash")
            }
        }
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { model.actionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.actionErrorMessage = nil
                }
            }
        )
    }

}
