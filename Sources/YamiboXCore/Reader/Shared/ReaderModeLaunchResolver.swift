import Foundation

/// Explicit mode switches open the reader itself, without changing board defaults.
public struct ReaderModeLaunchResolver: Sendable {
    private let progressStore: ReadingProgressStore
    private let settingsStore: SettingsStore
    private let directoryStore: any MangaDirectoryPersisting

    public init(dependencies: ForumDependencies) {
        progressStore = dependencies.readingProgressStore
        settingsStore = dependencies.settingsStore
        directoryStore = dependencies.mangaDirectoryStore
    }

    public func novelContext(
        thread: ThreadIdentity,
        title: String,
        authorID: String?,
        isPreview: Bool
    ) async -> NovelLaunchContext {
        let progress = await progressStore.load(for: .novelThread(threadID: thread.tid))?.novel
        return NovelLaunchContext(
            threadID: thread.tid,
            threadTitle: title,
            source: progress == nil ? .forum : .resume,
            initialView: progress?.novelResumePoint?.view ?? progress?.lastView ?? 1,
            authorID: progress?.novelResumePoint?.authorID ?? progress?.authorID ?? authorID,
            initialResumePoint: progress?.novelResumePoint,
            isPreview: isPreview
        )
    }

    public func mangaContext(
        thread: ThreadIdentity,
        title: String,
        isPreview: Bool
    ) async throws -> MangaLaunchContext {
        let smartMode = await settingsStore.load().isSmartComicModeEnabled(forumID: thread.fid)
        let directory = smartMode ? try await directoryStore.directory(containingTID: thread.tid) : nil
        let threadProgress = await progressStore.load(for: .mangaThread(threadID: thread.tid))?.manga
        let directoryProgress: MangaReadingProgressRecord?
        if let directory {
            directoryProgress = await progressStore.load(for: FavoriteContentTarget(
                mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName
            ))?.manga
        } else {
            directoryProgress = nil
        }
        let progress = directoryProgress ?? threadProgress
        let directoryName = smartMode ? directory?.cleanBookName ?? MangaTitleCleaner.cleanBookName(title) : nil
        return MangaLaunchContext(
            originalThreadID: thread.tid,
            chapterTID: progress?.chapterThreadID ?? thread.tid,
            displayTitle: directoryName ?? title,
            source: progress == nil ? .forum : .resume,
            chapterView: progress?.chapterView ?? 1,
            initialPage: progress?.mangaPageIndex ?? 0,
            directoryName: directoryName,
            isPreview: isPreview,
            isSmartModeEnabled: smartMode,
            forumID: thread.fid
        )
    }
}
