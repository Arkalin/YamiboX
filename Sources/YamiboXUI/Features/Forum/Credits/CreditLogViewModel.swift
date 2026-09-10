import Foundation
import Observation
import YamiboXCore

protocol CreditLogPageLoading: Sendable {
    func fetchCreditLog(filter: CreditLogFilter, page: Int) async throws -> CreditLogPage
}

extension UserSpaceRepository: CreditLogPageLoading {}

@MainActor
@Observable
final class CreditLogViewModel {
    private(set) var selectedFilter: CreditLogFilter = .all
    private(set) var content: CreditLogPage?
    private(set) var currentPage = 1
    private(set) var isLoading = false
    private(set) var errorDetails: LoadFailureDetails?

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any CreditLogPageLoading
    @ObservationIgnored private let sessionStore: SessionStore?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var failedPage: Int?

    init(dependencies: ForumDependencies) {
        repositoryProvider = { await dependencies.makeUserSpaceRepository() }
        sessionStore = dependencies.sessionStore
    }

    init(repository: any CreditLogPageLoading, sessionStore: SessionStore? = nil) {
        repositoryProvider = { repository }
        self.sessionStore = sessionStore
    }

    var scrollIdentity: String { "\(selectedFilter.rawValue):\(currentPage)" }

    var emptyMessage: String {
        switch selectedFilter {
        case .all: L10n.string("credit_log.empty")
        case .income: L10n.string("credit_log.empty_income")
        case .expense: L10n.string("credit_log.empty_expense")
        }
    }

    static func title(for filter: CreditLogFilter) -> String {
        switch filter {
        case .all: L10n.string("credit_log.all")
        case .income: L10n.string("credit_log.income")
        case .expense: L10n.string("credit_log.expense")
        }
    }

    func load() async {
        guard content == nil, !isLoading else { return }
        await loadPage(currentPage)
    }

    func selectFilter(_ filter: CreditLogFilter) async {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        currentPage = 1
        content = nil
        await loadPage(1)
    }

    func refresh() async {
        await loadPage(currentPage)
    }

    func retry() async {
        guard !isLoading else { return }
        await loadPage(failedPage ?? currentPage)
    }

    func goToPage(_ page: Int) async {
        let target = min(max(1, page), content?.pageNavigation?.totalPages ?? max(1, page))
        guard target != currentPage, !isLoading else { return }
        await loadPage(target)
    }

    private func loadPage(_ page: Int) async {
        generation += 1
        let requestGeneration = generation
        let filter = selectedFilter
        var accountGeneration: UUID?
        isLoading = true
        errorDetails = nil
        failedPage = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }

        do {
            let snapshot = try await sessionStore?.snapshot()
            accountGeneration = snapshot?.generation
            if let snapshot {
                guard snapshot.session.isLoggedIn, snapshot.session.hasValidAuthenticationCookie else {
                    throw YamiboError.notAuthenticated
                }
            }
            let repository = await repositoryProvider()
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let loaded = try await repository.fetchCreditLog(filter: filter, page: page)
            let accountIsCurrent = await isCurrentAccount(accountGeneration)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            guard accountIsCurrent else {
                content = nil
                return
            }
            content = loaded
            currentPage = loaded.pageNavigation?.currentPage ?? page
        } catch {
            let accountIsCurrent = await isCurrentAccount(accountGeneration)
            guard requestGeneration == generation, !Task.isCancelled,
                  !LoadDiagnosticError.isCancellation(error) else { return }
            guard accountIsCurrent else {
                content = nil
                return
            }
            if LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated { content = nil }
            failedPage = page
            errorDetails = LoadFailureDetails(
                error: error,
                requestContext: YamiboRoute.creditLog(filter: filter, page: page).url.absoluteString
            )
        }
    }

    private func isCurrentAccount(_ generation: UUID?) async -> Bool {
        guard let generation, let sessionStore else { return true }
        return await sessionStore.isCurrentGeneration(generation)
    }
}
