import Foundation

public enum ReaderChapterCommentsState: Equatable, Sendable {
    case idle
    case unsupported
    case loading(ReaderChapterCommentTarget)
    case loaded(ReaderChapterCommentTarget, ChapterCommentsPage)
    case failed(ReaderChapterCommentTarget, String)
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
    public var refreshError: String?

    public init(
        state: ReaderChapterCommentsState = .idle,
        isLoadingMore: Bool = false,
        loadMoreError: String? = nil,
        refreshError: String? = nil
    ) {
        self.state = state
        self.isLoadingMore = isLoadingMore
        self.loadMoreError = loadMoreError
        self.refreshError = refreshError
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

        public init(
            loadInitial: @escaping @Sendable (ReaderChapterCommentTarget) async throws -> ChapterCommentsPage,
            loadMore: @escaping @Sendable (ReaderChapterCommentTarget, Int) async throws -> ChapterCommentsPage
        ) {
            self.loadInitial = loadInitial
            self.loadMore = loadMore
        }
    }

    public private(set) var state: ReaderChapterCommentsState = .idle
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: String?
    public private(set) var refreshError: String?

    private let adapter: Adapter
    private var cache: [ReaderChapterCommentTarget: ChapterCommentsPage] = [:]
    private let onChange: (@Sendable (ReaderChapterCommentsSnapshot) -> Void)?

    public init(
        adapter: Adapter,
        onChange: (@Sendable (ReaderChapterCommentsSnapshot) -> Void)?
    ) {
        self.adapter = adapter
        self.onChange = onChange
    }

    public nonisolated(nonsending) func load(_ target: ReaderChapterCommentTarget?) async {
        guard let target else {
            state = .unsupported
            notifyChange()
            return
        }
        if let cached = cache[target] {
            refreshError = nil
            state = .loaded(target, cached)
            notifyChange()
            return
        }
        await refresh(target)
    }

    public nonisolated(nonsending) func refresh(_ target: ReaderChapterCommentTarget?) async {
        guard let target else {
            state = .unsupported
            notifyChange()
            return
        }
        state = .loading(target)
        loadMoreError = nil
        refreshError = nil
        notifyChange()
        do {
            let page = try await adapter.loadInitial(target)
            cache[target] = page
            state = .loaded(target, page)
        } catch {
            if let cached = cache[target] {
                refreshError = error.localizedDescription
                state = .loaded(target, cached)
            } else {
                state = .failed(target, error.localizedDescription)
            }
        }
        notifyChange()
    }

    public nonisolated(nonsending) func loadNextPage() async {
        guard case let .loaded(target, currentPage) = state,
              let nextView = currentPage.nextView,
              !isLoadingMore else {
            return
        }

        isLoadingMore = true
        loadMoreError = nil
        notifyChange()
        do {
            let nextPage = try await adapter.loadMore(target, nextView)
            let mergedPage = ChapterCommentsPage(
                target: target,
                comments: currentPage.comments + nextPage.comments,
                isBoundaryClosed: nextPage.isBoundaryClosed,
                nextView: nextPage.nextView
            )
            cache[target] = mergedPage
            state = .loaded(target, mergedPage)
            refreshError = nil
        } catch {
            loadMoreError = error.localizedDescription
        }
        isLoadingMore = false
        notifyChange()
    }

    private func notifyChange() {
        onChange?(
            ReaderChapterCommentsSnapshot(
                state: state,
                isLoadingMore: isLoadingMore,
                loadMoreError: loadMoreError,
                refreshError: refreshError
            )
        )
    }
}
