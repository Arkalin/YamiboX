import Foundation
import YamiboXCore

@MainActor
public enum FavoriteUpdateNotificationRouting {
    @discardableResult
    public static func open(notificationUserInfo userInfo: [AnyHashable: Any], dependencies: LibraryDependencies, appModel: YamiboAppModel) async -> Bool {
        guard let targetID = userInfo[FavoriteUpdateNotification.targetIDUserInfoKey] as? String else {
            return false
        }
        await open(targetID: targetID, dependencies: dependencies, appModel: appModel)
        return true
    }

    static func open(targetID: String, dependencies: LibraryDependencies, appModel: YamiboAppModel) async {
        let resolver = LocalFavoriteOpenTargetResolver(
            libraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore
        )
        do {
            let target: LocalFavoriteOpenTarget?
            if let directoryID = FavoriteUpdateTargetKey.mangaDirectoryID(fromID: targetID) {
                target = try await resolver.openTarget(forMangaDirectoryID: directoryID)
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
            case .novelDetail, .mangaDetail:
                appModel.selectTab(.favorites)
            case let .novelReader(context):
                appModel.selectTab(.favorites)
                appModel.presentNovelReader(context)
            case let .mangaReader(context):
                appModel.selectTab(.favorites)
                appModel.requestMangaReader(context)
            case let .nativeThread(url, title):
                appModel.openNativeForumThread(url: url, title: title)
            }
        } catch {
            YamiboLog.library.error("Failed to open favorite update notification target \(targetID): \(error.localizedDescription)")
            appModel.selectTab(.favorites)
        }
    }
}
