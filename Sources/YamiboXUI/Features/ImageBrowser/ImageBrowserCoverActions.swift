import Foundation
import YamiboXCore

/// One cover-related menu entry in the image browser. The browser stays
/// ignorant of the library: callers inject the actions that apply to their
/// context and the browser only renders and invokes them.
struct ImageBrowserCoverAction: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    /// Performs the action for the currently displayed image and returns the
    /// success feedback message. Throws (or returns nil) on failure.
    let perform: @Sendable (YamiboImageSource) async throws -> String?
}

typealias ImageBrowserCoverActionsProvider = @Sendable () async -> [ImageBrowserCoverAction]

/// Builds the cover actions for images viewed inside a forum thread: the
/// thread cover entry always applies; when the thread is a chapter of a
/// locally known manga directory, a second entry sets the manga's cover, and
/// restore entries appear for whichever keys currently hold a manual cover.
enum ImageBrowserThreadCoverActions {
    static func provider(
        tid: String,
        contentCoverStore: @escaping @Sendable () async -> ContentCoverStore?,
        mangaDirectoryStore: @escaping @Sendable () async -> (any MangaDirectoryPersisting)? = { nil },
        // Smart Comic Mode gate: when the tapped thread's board is not
        // currently configured as a smart-enabled manga board, the browser
        // has no manga-directory-aware UI at all, even if a `MangaDirectory`
        // technically still exists for this tid (e.g. a leftover from when
        // the board was previously configured). No default — every caller
        // supplies its own explicit configuration query (or `{ false }`
        // when it has no settings store to ask).
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
                            let key = ContentCoverKey.smartManga(cleanBookName: cleanBookName)
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
            guard try await store.setManualCover(source.url, for: key) else { return nil }
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
