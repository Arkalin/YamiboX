import Foundation
import YamiboXCore

/// Routes a tapped favorite-update notification to its favorite, reusing the
/// same resolver path as the in-app updates page (resume mode, board-default
/// manga scope). Falls back to the favorites tab when the favorite has been
/// deleted since the notification was delivered or resolution fails.
@MainActor
public enum FavoriteUpdateNotificationRouting {
    /// Entry point for the app delegate's notification-response handler.
    /// Returns false when the userInfo doesn't belong to a favorite-update
    /// notification, so unrelated notifications pass through untouched.
    @discardableResult
    public static func open(notificationUserInfo userInfo: [AnyHashable: Any], appModel: YamiboAppModel) async -> Bool {
        guard let targetID = userInfo[FavoriteUpdateNotification.targetIDUserInfoKey] as? String else {
            return false
        }
        await open(targetID: targetID, appModel: appModel)
        return true
    }

    static func open(targetID: String, appModel: YamiboAppModel) async {
        let dependencies = appModel.appContext.libraryDependencies
        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore
        )
        do {
            let target: LocalFavoriteOpenTarget?
            if let cleanBookName = FavoriteUpdateTargetKey.mangaDirectoryCleanBookName(fromID: targetID) {
                // A directory-mode event's notification carries no pointer to
                // one specific favorite — re-derive fresh, same as the
                // in-app updates page's tap handler.
                target = try await resolver.openTarget(forMangaDirectoryCleanBookName: cleanBookName)
            } else {
                let document = try? await dependencies.localFavoriteLibraryStore.load()
                guard let item = document?.items.first(where: { $0.target.id == targetID }) else {
                    appModel.selectTab(.favorites)
                    return
                }
                target = try await resolver.openTarget(for: item, mode: .resume, mangaScope: .boardDefault)
            }
            guard let target else {
                appModel.selectTab(.favorites)
                return
            }
            switch target {
            case let .novelReader(context):
                appModel.selectTab(.favorites)
                appModel.presentNovelReader(context)
            case let .mangaReader(context):
                appModel.selectTab(.favorites)
                appModel.presentMangaReader(context)
            case let .nativeThread(url, title):
                appModel.openNativeForumThread(url: url, title: title)
            }
        } catch {
            YamiboLog.library.error("Failed to open favorite update notification target \(targetID): \(error.localizedDescription)")
            appModel.selectTab(.favorites)
        }
    }
}
