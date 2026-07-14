import Foundation
import Observation
import YamiboXCore

public struct ForumNavigationRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let url: URL
    public let source: ForumNavigationSource
    public let title: String?

    public init(url: URL, source: ForumNavigationSource = .external, title: String? = nil) {
        self.url = url
        self.source = source
        self.title = title
    }
}

public struct ClipboardForumLinkPrompt: Identifiable, Equatable, Sendable {
    public let url: URL

    public var id: String { url.absoluteString }

    public init(url: URL) {
        self.url = url
    }
}

@MainActor
@Observable
public final class YamiboAppModel {
    public private(set) var bootstrapState: YamiboBootstrapState?
    public private(set) var isBootstrapping = false
    public var bootstrapErrorMessage: String?
    public private(set) var selectedTab: AppTab
    public var activeNovelContext: NovelLaunchContext?
    public var activeMangaContext: MangaLaunchContext?
    public private(set) var suspendedNovelContext: NovelLaunchContext?
    public private(set) var suspendedMangaContext: MangaLaunchContext?
    public private(set) var forumNavigationRequest: ForumNavigationRequest?
    public var clipboardForumLinkPrompt: ClipboardForumLinkPrompt?

    public let appContext: YamiboAppContext
    public let peripheralInput: ReaderPeripheralInputManager

    @ObservationIgnored private let appContinuity: AppContinuityWorkflow

    public init(appContext: YamiboAppContext, initialTab: AppTab = .forum) {
        self.appContext = appContext
        selectedTab = initialTab
        appContinuity = AppContinuityWorkflow(appContext: appContext)
        peripheralInput = ReaderPeripheralInputManager(settingsStore: appContext.settingsStore)
    }

    public func bootstrapIfNeeded() async {
        guard bootstrapState == nil, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        let result = await appContinuity.launchIfNeeded(canRestoreReaderRoute: canRestoreReaderRoute)
        bootstrapState = result.bootstrapState
        bootstrapErrorMessage = nil
        applyRestoredRoute(result.restoredRoute)
    }

    public func bootstrap() async {
        isBootstrapping = true
        defer { isBootstrapping = false }

        let state = await appContext.bootstrap()
        bootstrapState = state
        bootstrapErrorMessage = nil
        let restoredRoute = await appContinuity.restoreExplicitly(canRestoreReaderRoute: canRestoreReaderRoute)
        applyRestoredRoute(restoredRoute)
    }

    public func synchronizeWebDAVIfNeeded() {
        appContinuity.foregroundBecameActive()
    }

    public var hasActiveReaderPresentation: Bool {
        activeNovelContext != nil || activeMangaContext != nil
    }

    public func scheduleWebDAVUploadForLocalChange(touchesAppSettings: Bool = false) {
        appContinuity.localDataChanged(touchesAppSettings: touchesAppSettings)
    }

    public func scheduleWebDAVUploadForReadingProgressChange() {
        appContinuity.localDataChanged()
    }

    public func flushWebDAVSyncBeforeBackground() {
        appContinuity.willEnterBackground()
    }

    public func presentNovelReader(_ context: NovelLaunchContext) {
        suspendedNovelContext = nil
        activeNovelContext = context
        guard !context.isPreview else { return }
        appContinuity.readerRoutePresented(.novel(context))
    }

    public func selectTab(_ tab: AppTab) {
        selectedTab = tab
        restoreSuspendedNovelIfNeeded(for: tab)
        restoreSuspendedMangaIfNeeded(for: tab)
    }

    public func presentMangaReader(_ context: MangaLaunchContext) {
        suspendedMangaContext = nil
        activeMangaContext = context
        guard !context.isPreview else { return }
        appContinuity.readerRoutePresented(.manga(context))
    }

    public func dismissNovelReader(
        openThreadInForum url: URL? = nil,
        suspendedNovelContext: NovelLaunchContext? = nil,
        forumNavigationSource: ForumNavigationSource = .readerDiscussion
    ) {
        if url != nil {
            self.suspendedNovelContext = suspendedNovelContext ?? activeNovelContext
        } else {
            self.suspendedNovelContext = nil
        }
        activeNovelContext = nil
        appContinuity.readerRouteDismissed()
        if let url {
            selectedTab = .forum
            forumNavigationRequest = ForumNavigationRequest(url: url, source: forumNavigationSource)
        }
    }

    public func dismissMangaReader(
        openThreadInForum url: URL? = nil,
        suspendedMangaContext: MangaLaunchContext? = nil,
        forumNavigationSource: ForumNavigationSource = .readerDiscussion
    ) {
        if url != nil {
            self.suspendedMangaContext = suspendedMangaContext ?? activeMangaContext
        } else if activeMangaContext != nil {
            self.suspendedMangaContext = nil
        }
        activeMangaContext = nil
        appContinuity.readerRouteDismissed()
        if let url {
            selectedTab = .forum
            forumNavigationRequest = ForumNavigationRequest(url: url, source: forumNavigationSource)
        }
    }

    public func openForumURL(_ url: URL) {
        if activeNovelContext != nil {
            dismissNovelReader(openThreadInForum: url, forumNavigationSource: .external)
            return
        }

        if activeMangaContext != nil {
            dismissMangaReader(openThreadInForum: url, forumNavigationSource: .external)
            return
        }

        selectedTab = .forum
        forumNavigationRequest = ForumNavigationRequest(url: url)
    }

    public func openNativeForumThread(url: URL, title: String?) {
        selectedTab = .forum
        forumNavigationRequest = ForumNavigationRequest(url: url, source: .readerOrigin, title: title)
    }

    public func presentClipboardForumLinkPrompt(url: URL) {
        clipboardForumLinkPrompt = ClipboardForumLinkPrompt(url: url)
    }

    public func dismissClipboardForumLinkPrompt() {
        clipboardForumLinkPrompt = nil
    }

    public func confirmClipboardForumLinkPrompt(_ prompt: ClipboardForumLinkPrompt) {
        clipboardForumLinkPrompt = nil
        openForumURL(prompt.url)
    }

    public func updateReaderResumeRoute(_ route: ReaderResumeRoute) {
        switch route {
        case let .novel(context):
            guard activeNovelContext != nil else { return }
            activeNovelContext = context
        case let .manga(context):
            guard activeMangaContext != nil else { return }
            activeMangaContext = context
        }
        appContinuity.readerReadingPositionChanged(route)
    }

    private var canRestoreReaderRoute: Bool {
        activeNovelContext == nil && activeMangaContext == nil
    }

    private func applyRestoredRoute(_ route: ReaderResumeRoute?) {
        // Re-checked at apply time, not just when bootstrap sampled it: a
        // reader presented while bootstrap was still awaiting (e.g. from a
        // favorite-update notification tap on cold start) must not be
        // replaced by the restored resume route.
        guard let route, canRestoreReaderRoute else { return }
        switch route {
        case let .novel(context):
            activeNovelContext = context
        case let .manga(context):
            activeMangaContext = context
        }
    }

    private func restoreSuspendedNovelIfNeeded(for tab: AppTab) {
        guard tab == .favorites, let context = suspendedNovelContext else { return }
        suspendedNovelContext = nil
        activeNovelContext = context
        guard !context.isPreview else { return }
        appContinuity.readerRoutePresented(.novel(context))
    }

    private func restoreSuspendedMangaIfNeeded(for tab: AppTab) {
        guard tab == .favorites, let context = suspendedMangaContext else { return }
        suspendedMangaContext = nil
        activeMangaContext = context
        guard !context.isPreview else { return }
        appContinuity.readerRoutePresented(.manga(context))
    }
}
