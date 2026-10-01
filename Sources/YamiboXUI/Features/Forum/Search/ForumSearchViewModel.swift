import Foundation
import Observation
import YamiboXCore


@MainActor
@Observable
final class ForumSearchViewModel {
    var query = ""
    var page: ForumSearchPage?
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    private(set) var errorDetails: LoadFailureDetails?
    var isLoading = false
    var currentPage = 1
    var currentSearchID: String?

    let forumID: String?

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumSearchPageLoading
    @ObservationIgnored private let formHashProvider: @Sendable () async -> String?
    @ObservationIgnored private var generation = 0
    private struct RequestKey: Equatable {
        var query: String
        var forumID: String?
        var page: Int
    }
    @ObservationIgnored private var inFlightKey: RequestKey?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(forumID: String?, dependencies: ForumDependencies) {
        self.forumID = forumID
        repositoryProvider = {
            await dependencies.makeSearchRepository()
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

    func searchFirstPage() async {
        await search(pageNumber: 1)
    }

    func cancelSearch() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        inFlightKey = nil
        isLoading = false
    }

    func goToPage(_ pageNumber: Int) async {
        let nextPage = max(1, pageNumber)
        guard nextPage != currentPage else { return }
        await search(pageNumber: nextPage)
    }

    private func search(pageNumber: Int) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !Task.isCancelled else { return }
        let key = RequestKey(query: trimmedQuery, forumID: forumID, page: pageNumber)
        guard inFlightKey != key || searchTask?.isCancelled == true else { return }
        searchTask?.cancel()
        inFlightKey = key
        generation += 1
        let requestGeneration = generation
        let task = Task<Void, Never> { [weak self] in
            await self?.performSearch(key: key, requestGeneration: requestGeneration)
        }
        searchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == requestGeneration {
            inFlightKey = nil
            searchTask = nil
            isLoading = false
        }
    }

    private func performSearch(key: RequestKey, requestGeneration: Int) async {
        guard !Task.isCancelled, generation == requestGeneration else { return }
        let trimmedQuery = key.query
        let pageNumber = key.page
        let searchID = currentSearchID
        isLoading = true
        errorMessage = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }

        do {
            let repository = await repositoryProvider()
            try Task.checkCancellation()
            let nextPage: ForumSearchPage
            // Double-optional: outer nil means "leave currentSearchID
            // untouched" (the searchForumPage branch); `.some(nil)` means
            // "overwrite it with nil", matching the original unconditional
            // assignment in the searchForum branch.
            let resolvedSearchID: String??
            if pageNumber == 1 || searchID == nil {
                let formHash = await formHashProvider()
                try Task.checkCancellation()
                nextPage = try await repository.searchForum(
                    query: trimmedQuery,
                    forumID: forumID,
                    formHash: formHash
                )
                resolvedSearchID = .some(nextPage.searchID)
            } else {
                nextPage = try await repository.searchForumPage(
                    query: trimmedQuery,
                    searchID: searchID ?? "",
                    page: pageNumber
                )
                resolvedSearchID = nil
            }
            guard !Task.isCancelled, requestGeneration == generation else { return }
            if let resolvedSearchID {
                currentSearchID = resolvedSearchID
            }
            page = nextPage
            currentPage = nextPage.pageNavigation?.currentPage ?? pageNumber
            errorMessage = nil
        } catch {
            guard requestGeneration == generation, !Task.isCancelled,
                  !LoadDiagnosticError.isCancellation(error) else { return }
            page = nil
            currentPage = pageNumber
            if pageNumber == 1 { currentSearchID = nil }
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }
}
