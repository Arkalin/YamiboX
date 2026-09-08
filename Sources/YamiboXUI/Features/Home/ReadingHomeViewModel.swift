import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class ReadingHomeViewModel {
    private(set) var continuing: [ReadingHomeBook] = []
    private(set) var previous: [ReadingHomeBook] = []
    private(set) var hasLoaded = false
    private(set) var isOpening = false
    var openFailed = false

    @ObservationIgnored private let dependencies: LibraryDependencies
    @ObservationIgnored private let resolver: ReadingOpenTargetResolver
    @ObservationIgnored private var generation = 0

    init(dependencies: LibraryDependencies) {
        self.dependencies = dependencies
        resolver = ReadingOpenTargetResolver(
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore,
            historyWorkflow: dependencies.browsingHistoryWorkflow
        )
    }

    func reload() async {
        generation += 1
        let currentGeneration = generation
        let snapshot: BrowsingHistorySnapshot
        var favoritedThreadIDs: Set<String>?
        do {
            if await dependencies.settingsStore.load().system.homeShowsOnlyFavorites {
                let document = try await dependencies.localFavoriteLibraryStore.load()
                favoritedThreadIDs = Set(document.items.compactMap { $0.target.threadID })
            }
            if let workflow = dependencies.browsingHistoryWorkflow {
                snapshot = try await workflow.snapshot()
            } else {
                snapshot = await BrowsingHistorySnapshot(entries: dependencies.browsingHistoryStore?.entries() ?? [], boardReader: dependencies.settingsStore.load().boardReader)
            }
        } catch {
            YamiboLog.persistence.warning("Failed to load canonical reading history: \(error)")
            return
        }
        let settings = snapshot.boardReader
        let entries = snapshot.entries
        let shelf = ReadingHomeShelf(entries: entries, boardReader: settings, favoritedThreadIDs: favoritedThreadIDs)
        let keys = (shelf.continuing + shelf.previous).compactMap { ContentCoverKey(target: $0.target) }
        let covers = await dependencies.contentCoverStore.covers(for: keys)
        guard !Task.isCancelled, currentGeneration == generation else { return }

        func book(_ entry: BrowsingHistoryEntry) -> ReadingHomeBook {
            ReadingHomeBook(
                entry: entry,
                category: entry.category(boardReader: settings),
                isSmartManga: settings.isSmartComicModeEnabled(forumID: entry.forumID),
                coverURL: ContentCoverKey(target: entry.target).flatMap { covers[$0]?.resolvedURL }
            )
        }
        continuing = shelf.continuing.map(book)
        previous = shelf.previous.map(book)
        hasLoaded = true
    }

    func observe(_ changes: AsyncStream<String>) async {
        for await _ in changes {
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func open(_ entry: BrowsingHistoryEntry, using appModel: YamiboAppModel, bookOpeningTransition: BookOpeningTransition? = nil) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        guard let target = await resolver.openTarget(for: entry, origin: .home) else {
            openFailed = true
            return
        }
        guard !Task.isCancelled else { return }
        switch target {
        case let .novelReader(context): appModel.presentNovelReader(context, bookOpeningTransition: bookOpeningTransition)
        case let .mangaReader(context): await appModel.requestMangaReader(context, bookOpeningTransition: bookOpeningTransition).value
        case let .nativeThread(url, title): appModel.openNativeForumThread(url: url, title: title)
        }
    }
}
