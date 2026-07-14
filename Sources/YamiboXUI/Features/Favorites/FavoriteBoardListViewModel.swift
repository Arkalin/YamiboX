import Foundation
import Observation
import YamiboXCore

protocol BoardFavoriteManaging: Sendable {
    func fetchBoardFavoritesPage(page: Int) async throws -> BoardFavoriteRemotePage
    func deleteFavorite(remoteFavoriteID: String) async throws
}

extension FavoriteRepository: BoardFavoriteManaging {}

/// Drives the board-favorite management page. Board favorites are
/// intentionally network-only — unlike thread favorites there is no local
/// store or sync — so every load fetches the remote list and every delete
/// posts straight to the forum.
@MainActor
@Observable
final class FavoriteBoardListViewModel {
    private(set) var boards: [BoardFavorite]?
    private(set) var isLoading = false
    /// First-load failure with nothing to show; renders as a full-screen
    /// error state with retry.
    private(set) var errorMessage: String?
    /// Failures of row-level deletes and of refreshes that keep existing
    /// content; shown as an alert on top of the list.
    var actionErrorMessage: String?
    private var deletingFavoriteIDs: Set<String> = []

    /// The remote list pages at ~20 rows and favorited boards rarely exceed
    /// a couple of pages, so the page loads them all into one list. Cap
    /// guards against a runaway pager parse.
    private static let maxPages = 20

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any BoardFavoriteManaging

    init(repositoryProvider: @escaping @Sendable () async -> any BoardFavoriteManaging) {
        self.repositoryProvider = repositoryProvider
    }

    func load() async {
        guard boards == nil else { return }
        await reload()
    }

    func refresh() async {
        await reload()
    }

    func isDeleting(_ board: BoardFavorite) -> Bool {
        guard let favid = board.remoteFavoriteID else { return false }
        return deletingFavoriteIDs.contains(favid)
    }

    func delete(_ board: BoardFavorite) async {
        guard let favid = board.remoteFavoriteID else {
            actionErrorMessage = L10n.string("favorites.boards.missing_delete_id")
            return
        }
        guard deletingFavoriteIDs.insert(favid).inserted else { return }
        defer { deletingFavoriteIDs.remove(favid) }

        do {
            try await repositoryProvider().deleteFavorite(remoteFavoriteID: favid)
            boards?.removeAll { $0.fid == board.fid }
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let repository = await repositoryProvider()
            var all: [BoardFavorite] = []
            var seenFIDs = Set<String>()
            var page = 1
            var totalPages = 1
            repeat {
                let result = try await repository.fetchBoardFavoritesPage(page: page)
                for board in result.boards where seenFIDs.insert(board.fid).inserted {
                    all.append(board)
                }
                totalPages = min(result.totalPages, Self.maxPages)
                // The server clamps out-of-range requests to the last page;
                // trusting its reported page avoids refetching it forever.
                guard result.currentPage < totalPages else { break }
                page = max(page + 1, result.currentPage + 1)
            } while page <= totalPages
            boards = all
        } catch {
            if boards == nil {
                errorMessage = error.localizedDescription
            } else {
                actionErrorMessage = error.localizedDescription
            }
        }
    }
}
