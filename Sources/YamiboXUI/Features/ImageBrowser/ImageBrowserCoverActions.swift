import Foundation
import YamiboXCore

struct ImageBrowserCoverAction: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let perform: @Sendable (YamiboImageSource) async throws -> String?
}

typealias ImageBrowserCoverActionsProvider = @Sendable () async -> [ImageBrowserCoverAction]

enum ImageBrowserThreadCoverActions {
    static func provider(
        tid: String,
        contentCoverStore: @escaping @Sendable () async -> ContentCoverStore?,
        mangaDirectoryStore: @escaping @Sendable () async -> (any MangaDirectoryPersisting)? = { nil },
        isSmartComicModeEnabled: @escaping @Sendable () async -> Bool
    ) -> ImageBrowserCoverActionsProvider {
        {
            let trimmedTID = tid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTID.isEmpty, let store = await contentCoverStore() else { return [] }

            var actions: [ImageBrowserCoverAction] = []
            let threadKey = ContentCoverKey.thread(tid: trimmedTID)
            actions.append(setAction(
                id: "cover.set.thread",
                title: L10n.string("cover.set_as_cover"),
                key: threadKey,
                store: store
            ))

            var mangaKey: ContentCoverKey?
            var mangaBookName: String?
            if await isSmartComicModeEnabled(), let directoryStore = await mangaDirectoryStore() {
                do {
                    if let directory = try await directoryStore.directory(containingTID: trimmedTID) {
                        let cleanBookName = directory.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanBookName.isEmpty {
                            let key = ContentCoverKey.smartManga(directoryID: directory.id)
                            mangaKey = key
                            mangaBookName = cleanBookName
                            actions.append(setAction(
                                id: "cover.set.manga",
                                title: L10n.string("cover.set_as_manga_cover", cleanBookName),
                                key: key,
                                store: store
                            ))
                        }
                    }
                } catch {
                    YamiboLog.library.warning("Failed to look up manga directory for thread \(trimmedTID) while building cover actions: \(error)")
                }
            }

            if await hasManualCover(for: threadKey, store: store) {
                actions.append(restoreAction(
                    id: "cover.restore.thread",
                    title: L10n.string("cover.restore_auto_cover"),
                    key: threadKey,
                    store: store
                ))
            }
            if let mangaKey, let mangaBookName, await hasManualCover(for: mangaKey, store: store) {
                actions.append(restoreAction(
                    id: "cover.restore.manga",
                    title: L10n.string("cover.restore_auto_manga_cover", mangaBookName),
                    key: mangaKey,
                    store: store
                ))
            }
            return actions
        }
    }

    private static func setAction(
        id: String,
        title: String,
        key: ContentCoverKey,
        store: ContentCoverStore
    ) -> ImageBrowserCoverAction {
        ImageBrowserCoverAction(
            id: id,
            title: title,
            systemImage: "photo.on.rectangle.angled"
        ) { source in
            guard try await store.setManualCover(source, for: key) else { return nil }
            return L10n.string("cover.set_success_message")
        }
    }

    private static func restoreAction(
        id: String,
        title: String,
        key: ContentCoverKey,
        store: ContentCoverStore
    ) -> ImageBrowserCoverAction {
        ImageBrowserCoverAction(
            id: id,
            title: title,
            systemImage: "arrow.uturn.backward.circle"
        ) { _ in
            guard try await store.clearManualCover(for: key) else { return nil }
            return L10n.string("cover.restore_success_message")
        }
    }

    private static func hasManualCover(for key: ContentCoverKey, store: ContentCoverStore) async -> Bool {
        await store.cover(for: key)?.manualCoverURL != nil
    }
}
