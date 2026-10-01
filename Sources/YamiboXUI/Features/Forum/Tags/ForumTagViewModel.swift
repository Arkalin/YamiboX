import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class ForumTagViewModel {
    let target: ForumTagTarget
    private(set) var page: ForumTagPage?
    private(set) var currentPage: Int
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var errorDetails: LoadFailureDetails?
    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumTagPageLoading
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var requestedPage: Int?
    @ObservationIgnored private var retryPage: Int

    init(target: ForumTagTarget, initialPage: Int = 1, dependencies: ForumDependencies) {
        self.target = target
        currentPage = max(1, initialPage)
        retryPage = max(1, initialPage)
        repositoryProvider = { await dependencies.makeTagRepository() }
    }

    func load() async {
        guard page == nil else { return }
        await fetch(pageNumber: currentPage)
    }

    func refresh() async { await fetch(pageNumber: currentPage) }
    func retry() async { await fetch(pageNumber: retryPage) }

    func goToPage(_ number: Int) async {
        let number = max(1, number)
        guard number != currentPage,
              page?.pageNavigation?.totalPages.map({ number <= $0 }) ?? true else { return }
        await fetch(pageNumber: number)
    }

    func cancel() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        requestedPage = nil
        isLoading = false
    }

    private func fetch(pageNumber: Int) async {
        guard !Task.isCancelled, requestedPage != pageNumber else { return }
        cancel()
        let requestGeneration = generation
        requestedPage = pageNumber
        retryPage = pageNumber
        isLoading = true
        errorMessage = nil
        errorDetails = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let repository = await repositoryProvider()
                try Task.checkCancellation()
                let result = try await repository.fetchTagPage(target: target, page: pageNumber)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                page = result
                currentPage = result.pageNavigation?.currentPage ?? pageNumber
            } catch {
                guard !Task.isCancelled, generation == requestGeneration,
                      !LoadDiagnosticError.isCancellation(error) else { return }
                // Retain the last successful page during refresh/pagination errors.
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard generation == requestGeneration else { return }
        requestedPage = nil
        loadTask = nil
        isLoading = false
    }
}
