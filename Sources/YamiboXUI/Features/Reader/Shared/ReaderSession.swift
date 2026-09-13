import Foundation
import Observation
import YamiboXCore

enum ReaderSessionContent {
    case novel(NovelLaunchContext)
    case manga(MangaLaunchContext)
    case thread(ThreadNovelLaunchContext)

    var resumeRoute: ReaderResumeRoute? {
        switch self {
        case let .novel(context): .novel(context)
        case let .manga(context): .manga(context)
        case .thread: nil
        }
    }
}

struct ReaderSessionDependencies: Sendable {
    let forum: ForumDependencies
    let mangaReaderOpenValidator: MangaReaderOpenValidator
}

enum ReaderSessionPresentation {
    case fullScreen
    case embeddedThread
}

@MainActor
struct ReaderSessionLifecycle {
    var didActivate: @MainActor (ReaderSession, ReaderResumeRoute?) -> Void = { _, _ in }
    var didUpdateResumeRoute: @MainActor (ReaderSession, ReaderResumeRoute) -> Void = { _, _ in }
    var didDeactivate: @MainActor (ReaderSession) -> Void = { _ in }
    var didClose: @MainActor (ReaderSession) -> Void = { _ in }
    var didRequestFullScreen: @MainActor (ReaderSession, ReaderSessionContent, MangaReaderProjection?) -> Void = { _, _, _ in }
}

/// One navigation entry, with independently resumable reading modes.
@MainActor
@Observable
final class ReaderSession: Identifiable {
    let id = UUID()
    let bookOpeningTransition: BookOpeningTransition?
    let presentation: ReaderSessionPresentation
    private(set) var content: ReaderSessionContent
    private(set) var resumeRoute: ReaderResumeRoute?
    private(set) var contentID = UUID()
    private(set) var isSwitching = false
    private(set) var switchingTitle = L10n.string("reader.switching")
    @ObservationIgnored private(set) var preparedMangaProjection: MangaReaderProjection?
    private(set) var isClosed = false
    var switchFailure: LoadFailureDetails?
    let isPreview: Bool

    @ObservationIgnored private let dependencies: ReaderSessionDependencies
    @ObservationIgnored private let lifecycle: ReaderSessionLifecycle
    @ObservationIgnored private var novelContexts: [String: NovelLaunchContext] = [:]
    @ObservationIgnored private var mangaContexts: [String: MangaLaunchContext] = [:]
    @ObservationIgnored private var threadModels: [String: ForumThreadReaderViewModel] = [:]
    @ObservationIgnored private var switchTask: Task<Void, Never>?

    init(
        content: ReaderSessionContent,
        dependencies: ReaderSessionDependencies,
        lifecycle: ReaderSessionLifecycle,
        bookOpeningTransition: BookOpeningTransition? = nil,
        presentation: ReaderSessionPresentation = .fullScreen
    ) {
        self.content = content
        resumeRoute = content.resumeRoute
        self.dependencies = dependencies
        self.lifecycle = lifecycle
        self.bookOpeningTransition = bookOpeningTransition
        self.presentation = presentation
        switch content {
        case let .novel(context): isPreview = context.isPreview
        case let .manga(context): isPreview = context.isPreview
        case .thread: isPreview = false
        }
        if let route = content.resumeRoute { remember(route) }
    }

    deinit {
        switchTask?.cancel()
    }

    func activate() {
        guard !isClosed else { return }
        lifecycle.didActivate(self, resumeRoute)
    }

    func deactivate() {
        cancelSwitch()
        lifecycle.didDeactivate(self)
    }

    func close() {
        guard !isClosed else { return }
        cancelSwitch()
        isClosed = true
        lifecycle.didClose(self)
    }

    func present(_ content: ReaderSessionContent, mangaProjection: MangaReaderProjection? = nil) {
        guard !isClosed else { return }
        let previousRoute = resumeRoute
        prepareForContentPresentation()
        // A navigation column owns only its original thread. Reading gets a
        // separate full-window presentation without replacing that destination.
        if presentation == .embeddedThread, content.resumeRoute != nil {
            lifecycle.didRequestFullScreen(self, content, mangaProjection)
            return
        }
        self.content = content
        resumeRoute = content.resumeRoute
        preparedMangaProjection = mangaProjection
        contentID = UUID()
        if let route = content.resumeRoute { remember(route) }
        lifecycle.didActivate(self, previousRoute)
    }

    func prepareForContentPresentation() {
        cancelSwitch()
        if case let .thread(context) = content {
            threadModels[context.thread.tid]?.suspendForModeSwitch()
        }
    }

    func updateResumeRoute(_ route: ReaderResumeRoute, contentID: UUID) {
        // Teardown saves from the previous mode must not replace the new route.
        guard !isClosed, self.contentID == contentID, acceptsResumeRoute(route) else { return }
        remember(route)
        resumeRoute = route
        lifecycle.didUpdateResumeRoute(self, route)
    }

    func threadModel(for context: ThreadNovelLaunchContext, dependencies: ForumDependencies) -> ForumThreadReaderViewModel {
        if let model = threadModels[context.thread.tid] { return model }
        let model = ForumThreadReaderViewModel(context: context, dependencies: dependencies)
        model.persistsReadingActivity = !isPreview
        model.recordsReaderSessionHistory = true
        threadModels[context.thread.tid] = model
        return model
    }

    @discardableResult
    func openOriginalPost(url: URL, resumeRoute: ReaderResumeRoute) async -> Bool {
        guard !isSwitching, !isClosed, acceptsResumeRoute(resumeRoute) else { return false }
        let previousID = contentID
        updateResumeRoute(resumeRoute, contentID: previousID)
        let dependencies = self.dependencies.forum
        let title: String
        let authorID: String?
        let forumID: String?
        switch resumeRoute {
        case let .novel(context):
            title = context.threadTitle
            authorID = context.authorID
            forumID = threadModels[context.threadID]?.readerSwitchThread.fid ?? context.forumID
        case let .manga(context):
            title = context.displayTitle
            authorID = nil
            forumID = context.forumID
        }
        await transition(title: L10n.string("reader.switching_to_thread")) {
            let resolver = await dependencies.makeThreadRouteResolver()
            let target = try await resolver.resolve(YamiboThreadRouteRequest(
                threadURL: url,
                title: title,
                authorID: authorID,
                threadFid: forumID,
                intent: .nativeThreadReader
            ))
            switch target {
            case let .thread(payload), let .novel(payload), let .manga(payload), let .mangaDirect(payload):
                guard !payload.thread.tid.isEmpty else { throw ReaderSessionError.unavailableThread }
                return .thread(ThreadNovelLaunchContext(
                    thread: payload.thread,
                    title: payload.title,
                    initialPage: payload.initialPage,
                    targetPostID: payload.targetPostID,
                    authorID: payload.authorID,
                    isDiscussionView: true
                ))
            case .webFallback:
                throw ReaderSessionError.unavailableThread
            }
        }
        return !isClosed && previousID != contentID
    }

    func openReader(_ mode: YamiboThreadReaderOverride, from model: ForumThreadReaderViewModel) async {
        guard mode != .plainThread,
              case let .thread(context) = content,
              context.thread.tid == model.context.thread.tid else { return }
        let resolver = ReaderModeLaunchResolver(dependencies: dependencies.forum)
        let thread = model.readerSwitchThread
        let title = model.navigationTitle
        let authorID = model.readerSwitchAuthorID
        let savedNovel = novelContexts[thread.tid]
        let savedManga = mangaContexts[thread.tid]
        let preview = isPreview
        await transition(title: L10n.string(mode == .manga ? "reader.switching_to_manga" : "reader.switching_to_novel")) {
            switch mode {
            case .novel:
                if let savedNovel { return .novel(savedNovel) }
                return .novel(await resolver.novelContext(
                    thread: thread, title: title, authorID: authorID, isPreview: preview
                ))
            case .manga:
                let context: MangaLaunchContext
                if let savedManga {
                    context = savedManga
                } else {
                    context = try await resolver.mangaContext(thread: thread, title: title, isPreview: preview)
                }
                return .manga(context)
            case .plainThread:
                throw ReaderSessionError.unavailableThread
            }
        }
    }

    func openMangaReader(_ context: MangaLaunchContext) async {
        await transition(title: L10n.string("reader.switching_to_manga")) { .manga(context) }
    }

    private func acceptsResumeRoute(_ route: ReaderResumeRoute) -> Bool {
        switch (content, route) {
        case (.novel, .novel), (.manga, .manga): true
        default: false
        }
    }

    private func remember(_ route: ReaderResumeRoute) {
        switch route {
        case let .novel(context):
            novelContexts[context.threadID] = context
        case let .manga(context):
            mangaContexts[context.originalThreadID] = context
            mangaContexts[context.chapterTID] = context
        }
    }

    func transition(title: String = L10n.string("reader.switching"), _ resolve: @escaping @MainActor () async throws -> ReaderSessionContent) async {
        guard !isSwitching, !isClosed else { return }
        // Dismissing a cover need not trigger the retained column's onAppear.
        // An explicit mode switch restores its ownership before resolving.
        if presentation == .embeddedThread { activate() }
        isSwitching = true
        switchingTitle = title
        switchFailure = nil
        let expectedID = contentID
        let validator = dependencies.mangaReaderOpenValidator
        let task = Task { [weak self] in
            do {
                let next = try await resolve()
                guard !Task.isCancelled, self?.isClosed == false, self?.contentID == expectedID else { return }
                let mangaProjection: MangaReaderProjection?
                if case let .manga(context) = next {
                    mangaProjection = try await validator.validate(context)
                } else {
                    mangaProjection = nil
                }
                guard let self, !Task.isCancelled, !self.isClosed, self.contentID == expectedID else { return }
                self.present(next, mangaProjection: mangaProjection)
            } catch {
                guard let self, !Task.isCancelled, !self.isClosed, self.contentID == expectedID else { return }
                if !LoadDiagnosticError.isCancellation(error) {
                    self.switchFailure = LoadFailureDetails(error: error)
                }
                self.isSwitching = false
                self.switchTask = nil
            }
        }
        switchTask = task
        await task.value
    }

    func cancelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        isSwitching = false
    }
}

private enum ReaderSessionError: LocalizedError {
    case unavailableThread

    var errorDescription: String? { L10n.string("forum.open_native_failed") }
}
