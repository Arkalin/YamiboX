import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
@Test func favoriteBoardListLoadsAllPagesAndDeduplicates() async throws {
    let stub = BoardFavoriteRepositoryStub(pages: [
        1: BoardFavoriteRemotePage(
            boards: [
                BoardFavorite(fid: "30", title: "漫画交流区", remoteFavoriteID: "1"),
                BoardFavorite(fid: "44", title: "小说交流区", remoteFavoriteID: "2")
            ],
            currentPage: 1,
            totalPages: 2
        ),
        2: BoardFavoriteRemotePage(
            boards: [
                BoardFavorite(fid: "44", title: "小说交流区", remoteFavoriteID: "2"),
                BoardFavorite(fid: "55", title: "百合会", remoteFavoriteID: "3")
            ],
            currentPage: 2,
            totalPages: 2
        )
    ])
    let model = FavoriteBoardListViewModel(repositoryProvider: { stub })

    await model.load()

    #expect(model.boards?.map(\.fid) == ["30", "44", "55"])
    #expect(model.errorMessage == nil)
    #expect(await stub.fetchedPages() == [1, 2])

    // A second load with content already present must not refetch.
    await model.load()
    #expect(await stub.fetchedPages() == [1, 2])
}

@MainActor
@Test func favoriteBoardListFirstLoadFailureShowsFullScreenError() async throws {
    let stub = BoardFavoriteRepositoryStub(fetchError: YamiboError.notAuthenticated)
    let model = FavoriteBoardListViewModel(repositoryProvider: { stub })

    await model.load()

    #expect(model.boards == nil)
    #expect(model.errorMessage == YamiboError.notAuthenticated.localizedDescription)
}

@MainActor
@Test func favoriteBoardListRefreshFailureKeepsExistingContent() async throws {
    let stub = BoardFavoriteRepositoryStub(pages: [
        1: BoardFavoriteRemotePage(
            boards: [BoardFavorite(fid: "30", title: "漫画交流区", remoteFavoriteID: "1")],
            currentPage: 1,
            totalPages: 1
        )
    ])
    let model = FavoriteBoardListViewModel(repositoryProvider: { stub })

    await model.load()
    await stub.setFetchError(YamiboError.floodControl)
    await model.refresh()

    #expect(model.boards?.map(\.fid) == ["30"])
    #expect(model.errorMessage == nil)
    #expect(model.actionErrorMessage == YamiboError.floodControl.localizedDescription)
}

@MainActor
@Test func favoriteBoardListDeleteRemovesRowOnSuccess() async throws {
    let stub = BoardFavoriteRepositoryStub(pages: [
        1: BoardFavoriteRemotePage(
            boards: [
                BoardFavorite(fid: "30", title: "漫画交流区", remoteFavoriteID: "456"),
                BoardFavorite(fid: "44", title: "小说交流区", remoteFavoriteID: "789")
            ],
            currentPage: 1,
            totalPages: 1
        )
    ])
    let model = FavoriteBoardListViewModel(repositoryProvider: { stub })

    await model.load()
    let board = try #require(model.boards?.first)
    await model.delete(board)

    #expect(model.boards?.map(\.fid) == ["44"])
    #expect(model.actionErrorMessage == nil)
    #expect(await stub.deletedFavoriteIDs() == ["456"])
}

@MainActor
@Test func favoriteBoardListDeleteFailureKeepsRowAndSurfacesError() async throws {
    let stub = BoardFavoriteRepositoryStub(
        pages: [
            1: BoardFavoriteRemotePage(
                boards: [BoardFavorite(fid: "30", title: "漫画交流区", remoteFavoriteID: "456")],
                currentPage: 1,
                totalPages: 1
            )
        ],
        deleteError: FavoriteActionError.favoriteDeleteFailed
    )
    let model = FavoriteBoardListViewModel(repositoryProvider: { stub })

    await model.load()
    let board = try #require(model.boards?.first)
    await model.delete(board)

    #expect(model.boards?.map(\.fid) == ["30"])
    #expect(model.actionErrorMessage == FavoriteActionError.favoriteDeleteFailed.localizedDescription)
}

@MainActor
@Test func favoriteBoardListDeleteWithoutRemoteIDReportsWithoutRequest() async throws {
    let stub = BoardFavoriteRepositoryStub()
    let model = FavoriteBoardListViewModel(repositoryProvider: { stub })

    await model.delete(BoardFavorite(fid: "30", title: "漫画交流区", remoteFavoriteID: nil))

    #expect(model.actionErrorMessage == L10n.string("favorites.boards.missing_delete_id"))
    #expect(await stub.deletedFavoriteIDs().isEmpty)
}

private actor BoardFavoriteRepositoryStub: BoardFavoriteManaging {
    private var pages: [Int: BoardFavoriteRemotePage]
    private var fetchError: Error?
    private let deleteError: Error?
    private var recordedFetchedPages: [Int] = []
    private var recordedDeletedFavoriteIDs: [String] = []

    init(
        pages: [Int: BoardFavoriteRemotePage] = [:],
        fetchError: Error? = nil,
        deleteError: Error? = nil
    ) {
        self.pages = pages
        self.fetchError = fetchError
        self.deleteError = deleteError
    }

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func fetchedPages() -> [Int] {
        recordedFetchedPages
    }

    func deletedFavoriteIDs() -> [String] {
        recordedDeletedFavoriteIDs
    }

    func fetchBoardFavoritesPage(page: Int) async throws -> BoardFavoriteRemotePage {
        recordedFetchedPages.append(page)
        if let fetchError {
            throw fetchError
        }
        guard let result = pages[page] else {
            throw YamiboError.parsingFailed(context: "stub-page-\(page)")
        }
        return result
    }

    func deleteFavorite(remoteFavoriteID: String) async throws {
        if let deleteError {
            throw deleteError
        }
        recordedDeletedFavoriteIDs.append(remoteFavoriteID)
    }
}
