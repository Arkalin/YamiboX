#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
import Foundation
import YamiboXCore

/// BGAppRefreshTask wiring for automatic favorite update checks. iOS decides
/// the actual run timing; the foreground catch-up in the favorites tab covers
/// the gaps (`FavoriteUpdateMonitor.startCheckIfDue`).
public enum FavoriteUpdateBackgroundScheduler {
    public static let taskIdentifier = "com.arkalin.YamiboX.favoriteUpdates.refresh"

    /// Must run before the app finishes launching.
    @MainActor
    public static func register(appContext: YamiboAppContext) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await handle(refreshTask, appContext: appContext)
            }
        }
    }

    /// Submits the next refresh request based on the configured interval, or
    /// cancels pending ones when automatic checking is off. Call when the app
    /// enters the background.
    @MainActor
    public static func scheduleNextIfNeeded(appContext: YamiboAppContext) {
        Task { @MainActor in
            let monitor = makeMonitor(appContext: appContext)
            await monitor.load()
            guard let interval = await monitor.configuredInterval(),
                  let delay = interval.nextDelay(hasRecentEvents: monitor.hasRecentEvents) else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
                return
            }
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                YamiboLog.sync.warning("Failed to submit background refresh task \(taskIdentifier): \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private static func handle(_ task: BGAppRefreshTask, appContext: YamiboAppContext) async {
        let monitor = makeMonitor(appContext: appContext)
        await monitor.load()
        task.expirationHandler = {
            Task { @MainActor in
                await monitor.interrupt()
            }
        }
        // Background-task budget is tight — cap non-tag smart-manga
        // directory checks (the ones that risk the forum's search
        // flood-control) to just one per run, unlike the foreground
        // catch-up's more generous cap.
        let started = await monitor.startCheckIfDue(nonTagMangaDirectoryCheckCap: 1)
        if started {
            await monitor.waitForCompletion()
        }
        task.setTaskCompleted(success: monitor.snapshot?.status != .failed)
        scheduleNextIfNeeded(appContext: appContext)
    }

    @MainActor
    private static func makeMonitor(appContext: YamiboAppContext) -> FavoriteUpdateMonitor {
        let dependencies = appContext.libraryDependencies
        return FavoriteUpdateMonitor(
            updateStore: dependencies.favoriteUpdateStore,
            libraryStore: dependencies.localFavoriteLibraryStore,
            makeForumThreadReaderRepository: dependencies.makeForumThreadReaderRepository,
            settingsStore: dependencies.settingsStore,
            notifier: UserNotificationFavoriteUpdateNotifier(),
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            makeMangaDirectoryWorkflow: { searchForumID in
                MangaDirectoryWorkflow(
                    repository: await dependencies.makeMangaDirectoryRepository(),
                    store: dependencies.mangaDirectoryStore,
                    configuration: MangaDirectoryWorkflowConfiguration(searchForumID: searchForumID),
                    searchCooldownState: dependencies.mangaDirectorySearchCooldownState
                )
            }
        )
    }
}
#endif
