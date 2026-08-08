import Foundation
import Observation
import YamiboXCore

enum HomeContentKind: Hashable, Sendable {
    case novel
    case manga
    case smartManga

    var systemImageName: String {
        switch self {
        case .novel:
            "book.closed"
        case .manga:
            "rectangle.portrait.on.rectangle.portrait"
        case .smartManga:
            "sparkles"
        }
    }

    var localizedName: String {
        switch self {
        case .novel:
            L10n.string("home.content_type.novel")
        case .manga:
            L10n.string("home.content_type.manga")
        case .smartManga:
            L10n.string("home.content_type.smart_manga")
        }
    }
}

/// A reader-ready, local projection used by the Home surfaces. Keeping the
/// launch fallback alongside its display fields means the card/list views do
/// not need to know whether their data came from progress or an offline cache.
struct HomeReadingItem: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case readingProgress
        case offlineCache
    }

    let id: String
    let source: Source
    let title: String
    let kind: HomeContentKind
    let detail: String?
    let progressPercent: Int?
    let updatedAt: Date
    let cachedEntryCount: Int?
    let entry: BrowsingHistoryEntry?
    let fallbackNovelView: Int?
    let fallbackMangaView: Int
    let coverKey: ContentCoverKey?
    var coverURL: URL?

    var isSmartManga: Bool {
        kind == .smartManga
    }

    var accessibilityDescription: String {
        [title, kind.localizedName, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

@MainActor
@Observable
final class HomeViewModel {
    var readingItems: [HomeReadingItem] = []
    var cachedItems: [HomeReadingItem] = []
    var session = SessionState()
    var profile: YamiboProfile?
    var smartMangaBadgeEnabled = true
    var isLoading = false
    var hasLoaded = false

    @ObservationIgnored let profileAvatarLoader: YamiboProfileAvatarLoader
    @ObservationIgnored private let accountDependencies: AccountDependencies
    @ObservationIgnored private let libraryDependencies: LibraryDependencies
    @ObservationIgnored private let openTargetResolver: ReadingOpenTargetResolver
    @ObservationIgnored private var pendingReloadTask: Task<Void, Never>?

    init(accountDependencies: AccountDependencies, libraryDependencies: LibraryDependencies) {
        self.accountDependencies = accountDependencies
        self.libraryDependencies = libraryDependencies
        profileAvatarLoader = YamiboProfileAvatarLoader(sessionStore: accountDependencies.sessionStore)
        openTargetResolver = ReadingOpenTargetResolver(
            readingProgressStore: libraryDependencies.readingProgressStore,
            mangaDirectoryStore: accountDependencies.mangaDirectoryStore,
            settingsStore: libraryDependencies.settingsStore
        )
    }

    deinit {
        pendingReloadTask?.cancel()
    }

    var isLoggedIn: Bool {
        session.isLoggedIn && SessionState.hasAuthenticationCookie(session.cookie)
    }

    /// The most recent item is already represented by Continue Reading.
    var previouslyReadItems: [HomeReadingItem] {
        Self.previouslyReadItems(from: readingItems)
    }

    static func previouslyReadItems(from items: [HomeReadingItem]) -> [HomeReadingItem] {
        Array(items.dropFirst())
    }

    func load() async {
        await reload(showLoading: !hasLoaded)
    }

    func openTarget(for item: HomeReadingItem) async -> BrowsingHistoryOpenTarget? {
        guard let entry = item.entry else { return nil }
        return await openTargetResolver.openTarget(
            for: entry,
            origin: .home,
            fallbackNovelView: item.fallbackNovelView,
            fallbackMangaView: item.fallbackMangaView
        )
    }

    /// Store updates are intentionally coalesced. A reader often records a
    /// history position and progress update together, and Home should redraw
    /// once from a consistent local snapshot rather than momentarily showing
    /// one without the other.
    func scheduleReload() {
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload(showLoading: false)
        }
    }

    func observeReadingProgressChanges() async {
        for await _ in libraryDependencies.readingProgressStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeBrowsingHistoryChanges() async {
        guard let store = libraryDependencies.browsingHistoryStore else { return }
        for await _ in store.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeOfflineCacheChanges() async {
        for await _ in accountDependencies.offlineCacheStore.offlineCacheUpdates() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeContentCoverChanges() async {
        for await _ in libraryDependencies.contentCoverStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeSettingsChanges() async {
        for await _ in libraryDependencies.settingsStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeSessionChanges() async {
        for await _ in accountDependencies.sessionStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeProfileChanges() async {
        for await _ in accountDependencies.profileStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    private func reload(showLoading: Bool) async {
        guard !isLoading else { return }
        isLoading = showLoading

        async let loadedSession = accountDependencies.sessionStore.load()
        async let loadedProfile = accountDependencies.profileStore.load()
        async let loadedProgress = libraryDependencies.readingProgressStore.loadAll()
        async let loadedHistory = loadHistory()
        async let loadedCachedWorks = accountDependencies.offlineCacheStore.offlineCachedWorks()
        async let loadedSettings = libraryDependencies.settingsStore.load()

        let (session, profile, progress, history, cachedWorks, settings) = await (
            loadedSession,
            loadedProfile,
            loadedProgress,
            loadedHistory,
            loadedCachedWorks,
            loadedSettings
        )

        let historyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        let cachedByThreadID = Self.cachedWorksByThreadID(cachedWorks)
        let progressItems = progress
            .filter { $0.kind == .novel || $0.kind == .manga }
            .sorted(by: Self.isMoreRecent)
            .map {
                Self.progressItem(
                    record: $0,
                    history: historyByID[$0.id],
                    cachedWork: cachedWork(for: $0, in: cachedByThreadID),
                    boardReader: settings.boardReader
                )
            }

        let progressByThreadID = Self.progressByThreadID(progressItems)
        let cacheItems = cachedWorks.map {
            Self.cachedItem(
                work: $0,
                progressItem: progressByThreadID[Self.threadID(for: $0.launchTarget) ?? ""],
                boardReader: settings.boardReader
            )
        }

        let allItems = progressItems + cacheItems
        let covers = await libraryDependencies.contentCoverStore.covers(
            for: allItems.compactMap(\.coverKey)
        )
        readingItems = Self.applyingCoverURLs(to: progressItems, covers: covers)
        cachedItems = Self.applyingCoverURLs(to: cacheItems, covers: covers)
        self.session = session
        self.profile = profile
        smartMangaBadgeEnabled = settings.favorites.smartMangaBadgeEnabled
        hasLoaded = true
        isLoading = false
    }

    private func loadHistory() async -> [BrowsingHistoryEntry] {
        guard let store = libraryDependencies.browsingHistoryStore else { return [] }
        return await store.entries()
    }

    private func cachedWork(for record: ReadingProgressRecord, in works: [String: OfflineCachedWork]) -> OfflineCachedWork? {
        if let threadID = record.contentTarget?.threadID ?? record.threadID ?? record.manga?.chapterThreadID {
            return works[threadID]
        }
        return nil
    }

    static func isMoreRecent(_ lhs: ReadingProgressRecord, _ rhs: ReadingProgressRecord) -> Bool {
        let leftDate = lhs.lastReadAt ?? lhs.updatedAt
        let rightDate = rhs.lastReadAt ?? rhs.updatedAt
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return lhs.id < rhs.id
    }

    static func progressItem(
        record: ReadingProgressRecord,
        history: BrowsingHistoryEntry?,
        cachedWork: OfflineCachedWork?,
        boardReader: BoardReaderSettings
    ) -> HomeReadingItem {
        let target = record.contentTarget ?? fallbackTarget(for: record)
        let forumID = history?.forumID ?? forumID(for: cachedWork?.launchTarget)
        let kind = contentKind(for: record, target: target, forumID: forumID, boardReader: boardReader)
        let title = firstNonEmpty(
            history?.title,
            cachedWork?.title,
            target?.mangaCleanBookName,
            record.novel?.lastChapter,
            record.manga?.lastChapter,
            target?.threadID,
            record.threadID,
            record.id
        )
        let resolvedEntry = history ?? target.map {
            BrowsingHistoryEntry(
                target: $0,
                title: title,
                forumID: forumID,
                authorID: record.novel?.authorID,
                pageIndex: record.manga?.mangaPageIndex,
                pageCount: record.manga?.mangaPageCount,
                chapterTitle: record.novel?.lastChapter ?? record.manga?.lastChapter,
                chapterThreadID: record.manga?.chapterThreadID,
                lastVisitTime: record.lastReadAt ?? record.updatedAt
            )
        }
        let detail = readingDetail(for: record)
        let coverKey = coverKey(for: target, title: title, kind: kind)

        return HomeReadingItem(
            id: "progress:\(record.id)",
            source: .readingProgress,
            title: title,
            kind: kind,
            detail: detail,
            progressPercent: ReadingProgressPresentation.percent(for: record),
            updatedAt: record.lastReadAt ?? record.updatedAt,
            cachedEntryCount: nil,
            entry: resolvedEntry,
            fallbackNovelView: record.novel?.lastView,
            fallbackMangaView: record.manga?.chapterView ?? 1,
            coverKey: coverKey,
            coverURL: nil
        )
    }

    private static func cachedItem(
        work: OfflineCachedWork,
        progressItem: HomeReadingItem?,
        boardReader: BoardReaderSettings
    ) -> HomeReadingItem {
        let launchTarget = work.launchTarget
        let threadID = threadID(for: launchTarget) ?? work.id.ownerKey
        let forumID = forumID(for: launchTarget) ?? progressItem?.entry?.forumID
        let kind: HomeContentKind
        switch launchTarget {
        case .novel:
            kind = .novel
        case .manga:
            kind = progressItem?.kind == .smartManga || boardReader.isSmartComicModeEnabled(forumID: forumID)
                ? .smartManga
                : .manga
        }

        let title = firstNonEmpty(work.title, progressItem?.title, threadID)
        let target: FavoriteContentTarget
        let entry: BrowsingHistoryEntry
        let fallbackNovelView: Int?
        let fallbackMangaView: Int
        switch launchTarget {
        case let .novel(threadID, authorID, cachedView):
            target = .novelThread(threadID: threadID)
            entry = BrowsingHistoryEntry(
                target: target,
                title: title,
                authorID: authorID,
                lastVisitTime: work.updatedAt
            )
            fallbackNovelView = cachedView
            fallbackMangaView = 1
        case let .manga(threadID, chapterTitle, chapterView, forumID):
            target = .mangaThread(threadID: threadID)
            entry = BrowsingHistoryEntry(
                target: target,
                title: title,
                forumID: forumID,
                chapterTitle: chapterTitle,
                chapterThreadID: threadID,
                lastVisitTime: work.updatedAt
            )
            fallbackNovelView = nil
            fallbackMangaView = chapterView
        }

        return HomeReadingItem(
            id: "cache:\(work.id.readerKind.rawValue):\(work.id.ownerKey)",
            source: .offlineCache,
            title: title,
            kind: kind,
            detail: cacheDetail(for: work),
            progressPercent: progressItem?.progressPercent,
            updatedAt: work.updatedAt,
            cachedEntryCount: work.cachedEntryCount,
            entry: entry,
            fallbackNovelView: fallbackNovelView,
            fallbackMangaView: fallbackMangaView,
            coverKey: coverKey(for: progressItem?.entry?.target ?? target, title: title, kind: kind),
            coverURL: nil
        )
    }

    private static func fallbackTarget(for record: ReadingProgressRecord) -> FavoriteContentTarget? {
        switch record.kind {
        case .novel:
            guard let threadID = record.threadID else { return nil }
            return .novelThread(threadID: threadID)
        case .manga:
            guard let threadID = record.threadID ?? record.manga?.chapterThreadID else { return nil }
            return .mangaThread(threadID: threadID)
        case .thread:
            return nil
        }
    }

    private static func contentKind(
        for record: ReadingProgressRecord,
        target: FavoriteContentTarget?,
        forumID: String?,
        boardReader: BoardReaderSettings
    ) -> HomeContentKind {
        guard record.kind == .manga else { return .novel }
        if case .mangaTitle = target {
            return .smartManga
        }
        return boardReader.isSmartComicModeEnabled(forumID: forumID) ? .smartManga : .manga
    }

    private static func readingDetail(for record: ReadingProgressRecord) -> String? {
        ReadingProgressPresentation.positionText(for: record)
    }

    private static func cacheDetail(for work: OfflineCachedWork) -> String {
        L10n.string("home.cache_count", work.cachedEntryCount)
    }

    private static func coverKey(
        for target: FavoriteContentTarget?,
        title: String,
        kind: HomeContentKind
    ) -> ContentCoverKey? {
        if kind == .smartManga {
            if case let .mangaTitle(_, cleanBookName) = target {
                return .smartManga(cleanBookName: cleanBookName)
            }
            return .smartManga(cleanBookName: title)
        }
        return target.flatMap(ContentCoverKey.init(target:))
    }

    private static func cachedWorksByThreadID(_ works: [OfflineCachedWork]) -> [String: OfflineCachedWork] {
        Dictionary(
            works.compactMap { work in
                threadID(for: work.launchTarget).map { ($0, work) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func progressByThreadID(_ items: [HomeReadingItem]) -> [String: HomeReadingItem] {
        Dictionary(
            items.compactMap { item in
                (item.entry?.target.threadID ?? item.entry?.chapterThreadID).map { ($0, item) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func applyingCoverURLs(
        to items: [HomeReadingItem],
        covers: [ContentCoverKey: ContentCover]
    ) -> [HomeReadingItem] {
        items.map { item in
            var item = item
            item.coverURL = item.coverKey.flatMap { covers[$0]?.resolvedURL }
            return item
        }
    }

    private static func threadID(for launchTarget: OfflineCachedWorkLaunchTarget?) -> String? {
        guard let launchTarget else { return nil }
        switch launchTarget {
        case let .novel(threadID, _, _), let .manga(threadID, _, _, _):
            return threadID
        }
    }

    private static func forumID(for launchTarget: OfflineCachedWorkLaunchTarget?) -> String? {
        guard let launchTarget,
              case let .manga(_, _, _, forumID) = launchTarget else {
            return nil
        }
        return forumID
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? "--"
    }
}
