import Foundation

public enum ReaderChapterCommentsState: Equatable, Sendable {
    case idle
    case unsupported
    case loading(ReaderChapterCommentTarget)
    case loaded(ReaderChapterCommentTarget, ChapterCommentsPage)
    case failed(ReaderChapterCommentTarget, String, details: LoadFailureDetails? = nil)
}

public struct ReaderChapterCommentsUnavailableError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        L10n.string("reader.chapter_comments_failed")
    }
}

public struct ReaderChapterCommentsSnapshot: Equatable, Sendable {
    public var state: ReaderChapterCommentsState
    public var isLoadingMore: Bool
    public var loadMoreError: String?
    public var loadMoreErrorDetails: LoadFailureDetails?
    public var refreshError: String?
    public var refreshErrorDetails: LoadFailureDetails?
    public var failureEventID: UUID?

    public init(
        state: ReaderChapterCommentsState = .idle,
        isLoadingMore: Bool = false,
        loadMoreError: String? = nil,
        loadMoreErrorDetails: LoadFailureDetails? = nil,
        refreshError: String? = nil,
        refreshErrorDetails: LoadFailureDetails? = nil,
        failureEventID: UUID? = nil
    ) {
        self.state = state
        self.isLoadingMore = isLoadingMore
        self.loadMoreError = loadMoreError
        self.loadMoreErrorDetails = loadMoreErrorDetails
        self.refreshError = refreshError
        self.refreshErrorDetails = refreshErrorDetails
        self.failureEventID = failureEventID
    }
}

/// Caller-isolated (non-`Sendable`): state mutations happen in the isolation
/// domain of whoever drives the module, and `onChange` fires there with a
/// `Sendable` snapshot. The module makes no threading assumption; a UI owner is
/// responsible for hopping back to its own isolation (it drives the module
/// exclusively from there, so the callback provably arrives on it).
public final class ReaderChapterCommentsModule {
    public struct Adapter: Sendable {
        public var loadInitial: @Sendable (ReaderChapterCommentTarget) async throws -> ChapterCommentsPage
        public var loadMore: @Sendable (ReaderChapterCommentTarget, Int) async throws -> ChapterCommentsPage
        public var loadRatings: (@Sendable (ReaderChapterCommentTarget, ChapterCommentRatingRequest) async throws -> [ChapterComment])?

        public init(
            loadInitial: @escaping @Sendable (ReaderChapterCommentTarget) async throws -> ChapterCommentsPage,
            loadMore: @escaping @Sendable (ReaderChapterCommentTarget, Int) async throws -> ChapterCommentsPage,
            loadRatings: (@Sendable (ReaderChapterCommentTarget, ChapterCommentRatingRequest) async throws -> [ChapterComment])? = nil
        ) {
            self.loadInitial = loadInitial
            self.loadMore = loadMore
            self.loadRatings = loadRatings
        }
    }

    public private(set) var state: ReaderChapterCommentsState = .idle
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: String?
    public private(set) var loadMoreErrorDetails: LoadFailureDetails?
    public private(set) var refreshError: String?
    public private(set) var refreshErrorDetails: LoadFailureDetails?
    public private(set) var failureEventID: UUID?

    private let adapter: Adapter
    private var cache: [ReaderChapterCommentTarget: ChapterCommentsPage] = [:]
    private var generation = 0
    private var currentTarget: ReaderChapterCommentTarget?
    private var continuationID: UUID?
    private let onChange: (@Sendable (ReaderChapterCommentsSnapshot) -> Void)?

    public init(
        adapter: Adapter,
        onChange: (@Sendable (ReaderChapterCommentsSnapshot) -> Void)?
    ) {
        self.adapter = adapter
        self.onChange = onChange
    }

    public nonisolated(nonsending) func load(_ target: ReaderChapterCommentTarget?) async {
        _ = await loadPage(target)
    }

    private nonisolated(nonsending) func loadPage(_ target: ReaderChapterCommentTarget?) async -> Bool {
        if case let .loading(loadingTarget) = state, loadingTarget == target { return false }
        if currentTarget != target {
            generation += 1
            continuationID = nil
            currentTarget = target
            isLoadingMore = false
            loadMoreError = nil
            loadMoreErrorDetails = nil
            refreshError = nil
        }
        guard let target else {
            state = .unsupported
            notifyChange()
            return false
        }
        if let cached = cache[target] {
            refreshError = nil
            state = .loaded(target, cached)
            notifyChange()
            return true
        }
        return await refreshPage(target)
    }

    public func clearTransientFailure() {
        loadMoreError = nil
        loadMoreErrorDetails = nil
        refreshError = nil
        refreshErrorDetails = nil
        failureEventID = nil
        notifyChange()
    }

    public func cancelLoading() {
        generation += 1
        continuationID = nil
        isLoadingMore = false
        if let target = currentTarget, case .loading = state {
            state = cache[target].map { .loaded(target, $0) } ?? .idle
        }
        notifyChange()
    }

    public nonisolated(nonsending) func refresh(_ target: ReaderChapterCommentTarget?) async {
        _ = await refreshPage(target)
    }

    private nonisolated(nonsending) func refreshPage(_ target: ReaderChapterCommentTarget?) async -> Bool {
        generation += 1
        continuationID = nil
        currentTarget = target
        let requestGeneration = generation
        isLoadingMore = false
        loadMoreError = nil
        loadMoreErrorDetails = nil
        refreshError = nil
        guard let target else {
            state = .unsupported
            notifyChange()
            return false
        }
        state = cache[target].map { .loaded(target, $0) } ?? .loading(target)
        loadMoreError = nil
        refreshError = nil
        notifyChange()
        do {
            let page = try await adapter.loadInitial(target)
            guard requestGeneration == generation else { return false }
            guard !Task.isCancelled else {
                state = cache[target].map { .loaded(target, $0) } ?? .idle
                notifyChange()
                return false
            }
            cache[target] = page
            state = .loaded(target, page)
        } catch {
            guard requestGeneration == generation else { return false }
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else {
                state = cache[target].map { .loaded(target, $0) } ?? .idle
                notifyChange()
                return false
            }
            if let cached = cache[target] {
                refreshError = error.localizedDescription
                refreshErrorDetails = LoadFailureDetails(error: error)
                failureEventID = UUID()
                state = .loaded(target, cached)
            } else {
                state = .failed(target, error.localizedDescription, details: LoadFailureDetails(error: error))
            }
            notifyChange()
            return false
        }
        notifyChange()
        return true
    }

    public nonisolated(nonsending) func loadNextPage() async {
        guard case let .loaded(target, currentPage) = state,
              let nextView = currentPage.nextView,
              !isLoadingMore else {
            return
        }

        isLoadingMore = true
        loadMoreError = nil
        loadMoreErrorDetails = nil
        let requestGeneration = generation
        notifyChange()
        do {
            let nextPage = try await adapter.loadMore(target, nextView)
            guard requestGeneration == generation else { return }
            guard !Task.isCancelled else {
                isLoadingMore = false
                notifyChange()
                return
            }
            guard nextPage.nextView.map({ $0 > nextView }) ?? true else {
                throw ReaderChapterCommentsUnavailableError()
            }
            var mergedPage = currentPage
            mergedPage.append(nextPage)
            cache[target] = mergedPage
            state = .loaded(target, mergedPage)
            refreshError = nil
        } catch {
            guard requestGeneration == generation else { return }
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                loadMoreError = error.localizedDescription
                loadMoreErrorDetails = LoadFailureDetails(error: error)
                failureEventID = UUID()
            }
        }
        isLoadingMore = false
        notifyChange()
    }

    public nonisolated(nonsending) func loadAndContinue(_ target: ReaderChapterCommentTarget?) async {
        guard await loadPage(target), currentTarget == target, !Task.isCancelled else { return }
        await continueLoading()
    }

    public nonisolated(nonsending) func refreshAndContinue(_ target: ReaderChapterCommentTarget?) async {
        guard await refreshPage(target), currentTarget == target, !Task.isCancelled else { return }
        await continueLoading()
    }

    /// Runs in the caller's task: the sheet owns cancellation, while all list
    /// levels observe the same incremental snapshots and retry cursor.
    public nonisolated(nonsending) func continueLoading() async {
        guard continuationID == nil, case .loaded = state, !Task.isCancelled else { return }
        let id = UUID()
        continuationID = id
        let requestGeneration = generation
        defer {
            if continuationID == id {
                continuationID = nil
                isLoadingMore = false
                notifyChange()
            }
        }
        loadMoreError = nil
        loadMoreErrorDetails = nil
        while requestGeneration == generation, !Task.isCancelled,
              case let .loaded(target, page) = state {
            guard page.needsInitialRetry != true else { return }
            if page.nextView != nil, !page.isBoundaryClosed {
                let cursor = page.nextView
                await loadNextPage()
                guard loadMoreError == nil, case let .loaded(_, updated) = state,
                      updated.nextView != cursor else { return }
                continue
            }
            if let request = page.pendingRatings?.first, let loadRatings = adapter.loadRatings {
                isLoadingMore = true
                notifyChange()
                do {
                    let ratings = try await loadRatings(target, request)
                    guard requestGeneration == generation, !Task.isCancelled else { return }
                    var updated = page
                    updated.replaceRatings(ratings, request: request)
                    cache[target] = updated
                    state = .loaded(target, updated)
                    notifyChange()
                    continue
                } catch {
                    guard requestGeneration == generation else { return }
                    if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                        loadMoreError = error.localizedDescription
                        loadMoreErrorDetails = LoadFailureDetails(error: error)
                        failureEventID = UUID()
                    }
                    return
                }
            }
            return
        }
    }

    private func notifyChange() {
        onChange?(
            ReaderChapterCommentsSnapshot(
                state: state,
                isLoadingMore: isLoadingMore,
                loadMoreError: loadMoreError,
                loadMoreErrorDetails: loadMoreErrorDetails,
                refreshError: refreshError,
                refreshErrorDetails: refreshError == nil ? nil : refreshErrorDetails,
                failureEventID: failureEventID
            )
        )
    }
}
