import Foundation
import Observation
import YamiboXCore

protocol ForumSearchPageLoading: Sendable {
    func searchForum(query: String, forumID: String?, formHash: String?) async throws -> ForumSearchPage
    func searchForumPage(query: String, searchID: String, page: Int) async throws -> ForumSearchPage
}

extension ForumRepository: ForumSearchPageLoading {}

@MainActor
@Observable
final class ForumSearchViewModel {
    private struct PageSnapshot {
        var page: ForumSearchPage?
        var errorMessage: String?
        var currentPage: Int
        var currentSearchID: String?
    }

    var query = ""
    var page: ForumSearchPage?
    var errorMessage: String?
    var isLoading = false
    var currentPage = 1
    var currentSearchID: String?

    let forumID: String?

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumSearchPageLoading
    @ObservationIgnored private let formHashProvider: @Sendable () async -> String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private lazy var pageNavigator = ForumPageNavigator<PageSnapshot>(
        capture: { [unowned self] in
            PageSnapshot(
                page: page,
                errorMessage: errorMessage,
                currentPage: currentPage,
                currentSearchID: currentSearchID
            )
        },
        restore: { [unowned self] snapshot in
            generation += 1
            page = snapshot.page
            errorMessage = snapshot.errorMessage
            currentPage = snapshot.currentPage
            currentSearchID = snapshot.currentSearchID
            // The generation bump turns any in-flight search stale; its
            // generation-guarded defer will no longer clear the spinner, so
            // the restore clears it here (mirroring ForumBoardViewModel).
            isLoading = false
        }
    )

    init(forumID: String?, dependencies: ForumDependencies) {
        self.forumID = forumID
        repositoryProvider = {
            await dependencies.makeForumRepository()
        }
        formHashProvider = {
            await dependencies.profileStore.load()?.formHash
        }
    }

    init(
        forumID: String?,
        repository: any ForumSearchPageLoading,
        formHash: String?
    ) {
        self.forumID = forumID
        repositoryProvider = {
            repository
        }
        formHashProvider = {
            formHash
        }
    }

    var results: [ForumThreadSummary] {
        page?.results ?? []
    }

    var pageNavigation: ForumPageNavigation? {
        page?.pageNavigation
    }

    var resultCountText: String? {
        guard let totalCount = page?.totalCount else { return nil }
        return L10n.string("forum.search.result_count", totalCount)
    }

    var canRestorePreviousPage: Bool {
        pageNavigator.canRestorePreviousPage
    }

    func searchFirstPage() async {
        pageNavigator.reset()
        currentPage = 1
        currentSearchID = nil
        await search(pageNumber: 1, recordsHistory: false)
    }

    func goToPage(_ pageNumber: Int) async {
        let nextPage = max(1, pageNumber)
        guard nextPage != currentPage else { return }
        await search(pageNumber: nextPage, recordsHistory: true)
    }

    @discardableResult
    func restorePreviousPage() -> Bool {
        pageNavigator.restorePreviousPage()
    }

    private func search(pageNumber: Int, recordsHistory: Bool) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        if recordsHistory {
            pageNavigator.recordCurrentPage()
        }

        generation += 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }

        do {
            let repository = await repositoryProvider()
            let nextPage: ForumSearchPage
            // Double-optional: outer nil means "leave currentSearchID
            // untouched" (the searchForumPage branch); `.some(nil)` means
            // "overwrite it with nil", matching the original unconditional
            // assignment in the searchForum branch.
            let resolvedSearchID: String??
            if pageNumber == 1 || currentSearchID == nil {
                nextPage = try await repository.searchForum(
                    query: trimmedQuery,
                    forumID: forumID,
                    formHash: await formHashProvider()
                )
                resolvedSearchID = .some(nextPage.searchID)
            } else {
                nextPage = try await repository.searchForumPage(
                    query: trimmedQuery,
                    searchID: currentSearchID ?? "",
                    page: pageNumber
                )
                resolvedSearchID = nil
            }
            guard requestGeneration == generation else { return }
            if let resolvedSearchID {
                currentSearchID = resolvedSearchID
            }
            page = nextPage
            currentPage = nextPage.pageNavigation?.currentPage ?? pageNumber
            errorMessage = nil
        } catch {
            guard requestGeneration == generation else { return }
            if recordsHistory {
                pageNavigator.discardLastRecord()
            }
            page = nil
            currentPage = pageNumber
            errorMessage = error.localizedDescription
        }
    }
}
