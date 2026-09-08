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

/// One navigation entry, with independently resumable reading modes.
@MainActor
@Observable
final class ReaderSession: Identifiable {
    let id = UUID()
    let bookOpeningTransition: BookOpeningTransition?
    private(set) var content: ReaderSessionContent
    private(set) var contentID = UUID()
    private(set) var isSwitching = false
    private(set) var switchingTitle = L10n.string("reader.switching")
    @ObservationIgnored private(set) var preparedMangaProjection: MangaReaderProjection?
    private(set) var isClosed = false
    var switchFailure: LoadFailureDetails?
    let isPreview: Bool

    @ObservationIgnored private weak var appModel: YamiboAppModel?
    @ObservationIgnored private var novelContexts: [String: NovelLaunchContext] = [:]
    @ObservationIgnored private var mangaContexts: [String: MangaLaunchContext] = [:]
    @ObservationIgnored private var threadModels: [String: ForumThreadReaderViewModel] = [:]
    @ObservationIgnored private var switchTask: Task<Void, Never>?

    init(content: ReaderSessionContent, appModel: YamiboAppModel, bookOpeningTransition: BookOpeningTransition? = nil) {
        self.content = content
        self.appModel = appModel
        self.bookOpeningTransition = bookOpeningTransition
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
        appModel?.activateReaderSession(self, route: latestResumeRoute)
    }

    func deactivate() {
        cancelSwitch()
        appModel?.deactivateReaderSession(self)
    }

    func close() {
        cancelSwitch()
        isClosed = true
        appModel?.finishReaderSession(self)
    }

    func present(_ content: ReaderSessionContent, mangaProjection: MangaReaderProjection? = nil) {
        guard !isClosed else { return }
        cancelSwitch()
        if case let .thread(context) = self.content {
            threadModels[context.thread.tid]?.suspendForModeSwitch()
        }
        self.content = content
        preparedMangaProjection = mangaProjection
        contentID = UUID()
        if let route = content.resumeRoute { remember(route) }
        activate()
    }

    func updateResumeRoute(_ route: ReaderResumeRoute, contentID: UUID) {
        // Teardown saves from the previous mode must not replace the new route.
        guard !isClosed, self.contentID == contentID, content.resumeRoute != nil else { return }
        remember(route)
        appModel?.updateReaderSessionResumeRoute(route, session: self)
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
        guard let appModel, !isSwitching, !isClosed else { return false }
        let previousID = contentID
        remember(resumeRoute)
        let dependencies = appModel.appContext.forumDependencies
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
        guard let appModel, mode != .plainThread,
              case let .thread(context) = content,
              context.thread.tid == model.context.thread.tid else { return }
        let resolver = ReaderModeLaunchResolver(dependencies: appModel.appContext.forumDependencies)
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

    private var latestResumeRoute: ReaderResumeRoute? {
        switch content {
        case let .novel(context): .novel(novelContexts[context.threadID] ?? context)
        case let .manga(context): .manga(mangaContexts[context.originalThreadID] ?? context)
        case .thread: nil
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
        isSwitching = true
        switchingTitle = title
        switchFailure = nil
        let expectedID = contentID
        let task = Task { [weak self] in
            do {
                let next = try await resolve()
                let mangaProjection: MangaReaderProjection?
                if case let .manga(context) = next, let appModel = self?.appModel {
                    mangaProjection = try await appModel.mangaReaderOpenValidator.validate(context)
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
