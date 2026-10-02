import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class BookshelfViewModel {
    private(set) var continuing: [BookshelfBook] = []
    private(set) var previous: [BookshelfBook] = []
    private(set) var hasLoaded = false
    private(set) var loadErrorMessage: String?
    private(set) var loadErrorDetails: LoadFailureDetails?
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
            historyWorkflow: dependencies.browsingHistoryWorkflow
        )
    }

    func reload() async {
        generation += 1
        let currentGeneration = generation
        let snapshot: BrowsingHistorySnapshot
        let systemSettings = await dependencies.settingsStore.load().system
        var favorites: FavoriteMembershipSnapshot?
        do {
            snapshot = try await dependencies.browsingHistoryWorkflow.snapshot()
            if systemSettings.homeShowsOnlyFavorites {
                favorites = try await FavoriteMembershipSnapshot.load(
                    libraryStore: dependencies.localFavoriteLibraryStore,
                    directoryStore: dependencies.mangaDirectoryStore,
                    boardReader: snapshot.boardReader,
                    additionalThreadIDs: snapshot.entries.map { FavoriteMembershipScope(entry: $0, boardReader: snapshot.boardReader).threadID }
                )
            }
        } catch {
            guard currentGeneration == generation, !Task.isCancelled,
                  !LoadDiagnosticError.isCancellation(error) else { return }
            loadErrorMessage = error.localizedDescription
            loadErrorDetails = LoadFailureDetails(error: error)
            YamiboLog.persistence.warning("Failed to load canonical reading history: \(error)")
            return
        }
        let settings = snapshot.boardReader
        let entries = snapshot.entries
        let shelf = BookshelfShelf(
            entries: entries,
            boardReader: settings,
            favorites: favorites,
            continueSettings: systemSettings.bookshelfContinue
        )
        let keys = (shelf.continuing + shelf.previous).compactMap { ContentCoverKey(target: $0.target) }
        let covers = await dependencies.contentCoverStore.covers(for: keys)
        guard !Task.isCancelled, currentGeneration == generation else { return }
        loadErrorMessage = nil
        loadErrorDetails = nil

        func book(_ entry: BrowsingHistoryEntry) -> BookshelfBook {
            BookshelfBook(
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

    func open(
        _ entry: BrowsingHistoryEntry,
        navigate: @MainActor (BrowsingHistoryOpenTarget) async -> Void
    ) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        do {
            guard let target = try await resolver.openTarget(for: entry, origin: .home) else {
                openFailed = true
                return
            }
            guard !Task.isCancelled else { return }
            await navigate(target)
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            YamiboLog.persistence.warning("Failed to resolve reading position: \(error)")
            openFailed = true
        }
    }
}
