import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Test func readerOverlayNavigatorPushesThreadRoutesAsInPlaceThreadLinks() throws {
    let navigator = try makeNavigator(mode: .readerOverlay)
    let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&ptid=123&pid=456")!

    navigator.route(url, source: .external)

    #expect(navigator.path == [
        .threadLink(url: url, title: nil, containingFid: nil, authorID: nil, isDiscussionView: false)
    ])
}

@MainActor
@Test func readerOverlayNavigatorPushesThreadSummariesAsThreadLinks() throws {
    let navigator = try makeNavigator(mode: .readerOverlay)
    let url = URL(string: "https://bbs.yamibo.com/thread-123-1-1.html")!
    let summary = ForumThreadSummary(tid: "123", title: "某帖", url: url, fid: "5", authorID: "42")

    navigator.openThread(summary, containingFid: nil)

    #expect(navigator.path == [
        .threadLink(url: url, title: "某帖", containingFid: "5", authorID: "42", isDiscussionView: false)
    ])
}

@MainActor
@Test func readerOverlayNavigatorMarksExplicitDiscussionPushes() throws {
    let navigator = try makeNavigator(mode: .readerOverlay)
    let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!

    navigator.pushThreadLink(url: url, title: "作品名", isDiscussionView: true)

    #expect(navigator.path == [
        .threadLink(url: url, title: "作品名", containingFid: nil, authorID: nil, isDiscussionView: true)
    ])
}

@MainActor
@Test func readerOverlayNavigatorKeepsHomeRoutesInsideTheOverlay() throws {
    let navigator = try makeNavigator(mode: .readerOverlay)
    let threadURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
    let homeURL = URL(string: "https://bbs.yamibo.com/forum.php")!
    navigator.pushThreadLink(url: threadURL, title: nil)

    navigator.route(homeURL, source: .external)

    #expect(navigator.path.count == 2)
    #expect(navigator.path.last == .web(homeURL))
}

@MainActor
@Test func forumTabNavigatorStillPopsToRootForHomeRoutes() throws {
    let navigator = try makeNavigator(mode: .forumTab)
    let homeURL = URL(string: "https://bbs.yamibo.com/forum.php")!
    navigator.push(.web(URL(string: "https://example.com")!))

    navigator.route(homeURL, source: .external)

    #expect(navigator.path.isEmpty)
}

/// Threads of the reader's own work opened inside the overlay must stay
/// discussion companions, or their plain-thread history rows would absorb the
/// work's main-form row (browsing-history decision #14 / finding P1-B).
@MainActor
@Test func threadLinkLaunchContextForcesDiscussionViewForWorkTIDs() throws {
    let navigator = try makeNavigator(mode: .readerOverlay, discussionWorkTIDs: ["123", "777"])
    let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
    let workPayload = YamiboThreadRoutePayload(
        thread: ThreadIdentity(tid: "123", fid: "5"),
        title: "作品帖",
        canonicalURL: url,
        requestedURL: url
    )
    let otherPayload = YamiboThreadRoutePayload(
        thread: ThreadIdentity(tid: "999", fid: "5"),
        title: "别的帖",
        canonicalURL: url,
        requestedURL: url
    )

    #expect(navigator.threadLinkLaunchContext(for: workPayload, isDiscussionView: false).isDiscussionView)
    #expect(navigator.threadLinkLaunchContext(for: workPayload, isDiscussionView: true).isDiscussionView)
    #expect(!navigator.threadLinkLaunchContext(for: otherPayload, isDiscussionView: false).isDiscussionView)
}

/// Builds a navigator on top of per-test stores. Repository/resolver factories
/// trap loudly: neither mode may touch them synchronously, and the
/// `.readerOverlay` mode must push thread links without resolving at all.
@MainActor
private func makeNavigator(
    mode: ForumNavigationMode,
    discussionWorkTIDs: Set<String> = []
) throws -> ForumDestinationNavigator {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "forum-destination-navigator")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let settingsStore = SettingsStore(defaults: defaults, key: "settings")
    let dependencies = ForumDependencies(
        sessionStore: sessionStore,
        profileStore: YamiboProfileStore(defaults: defaults, key: "profile"),
        localFavoriteLibraryStore: FavoriteLibraryStore(defaults: defaults, key: "local-favorites"),
        readingProgressStore: ReadingProgressStore(defaults: defaults, key: "reading-progress"),
        settingsStore: settingsStore,
        contentCoverStore: ContentCoverStore(defaults: defaults, key: "content-covers"),
        mangaDirectoryStore: NavigatorTestsUnusedMangaDirectoryStore(),
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState(),
        makeForumRepository: { fatalError("makeForumRepository is not exercised by ForumDestinationNavigatorTests") },
        makeForumThreadReaderRepository: { fatalError("makeForumThreadReaderRepository is not exercised by ForumDestinationNavigatorTests") },
        makeUserSpaceRepository: { fatalError("makeUserSpaceRepository is not exercised by ForumDestinationNavigatorTests") },
        makeBlogReaderRepository: { fatalError("makeBlogReaderRepository is not exercised by ForumDestinationNavigatorTests") },
        makeFavoriteRepository: { fatalError("makeFavoriteRepository is not exercised by ForumDestinationNavigatorTests") },
        makeNovelReaderRepository: { fatalError("makeNovelReaderRepository is not exercised by ForumDestinationNavigatorTests") },
        makeMangaReaderProjectionLoader: { fatalError("makeMangaReaderProjectionLoader is not exercised by ForumDestinationNavigatorTests") },
        makeMangaDirectoryRepository: { fatalError("makeMangaDirectoryRepository is not exercised by ForumDestinationNavigatorTests") },
        makeThreadRouteResolver: { fatalError("navigator pushes must not resolve thread routes synchronously") }
    )
    let navigatorRootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("forum-destination-navigator-\(UUID().uuidString)", isDirectory: true)
    let appContext = YamiboAppContext(
        sessionStore: sessionStore,
        settingsStore: settingsStore,
        webDAVSyncSettingsStore: try WebDAVSyncSettingsStore(testSuiteName: suiteName, key: "webdav"),
        readerResumeRouteStore: try ReaderResumeRouteStore(testSuiteName: suiteName, key: "reader-route"),
        grdbRootDirectory: navigatorRootDirectory,
        cachesRootDirectory: navigatorRootDirectory
    )
    return ForumDestinationNavigator(
        dependencies: dependencies,
        appModel: YamiboAppModel(appContext: appContext),
        mode: mode,
        discussionWorkTIDs: discussionWorkTIDs
    )
}

private struct NavigatorTestsUnusedMangaDirectoryStore: MangaDirectoryPersisting {
    func directory(named name: String) async throws -> MangaDirectory? { nil }
    func directory(containingTID tid: String) async throws -> MangaDirectory? { nil }
    func saveDirectory(_ directory: MangaDirectory) async throws {}
    func deleteDirectory(named name: String) async throws {}
}
