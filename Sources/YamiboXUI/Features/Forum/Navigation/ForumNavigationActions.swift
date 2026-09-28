import Foundation
import YamiboXCore

/// The navigator can present readers and reject stale account work, but cannot
/// look up application services or mutate unrelated application state.
@MainActor
struct ForumNavigationActions {
    var accountGeneration: @MainActor () -> UUID
    var presentNovel: @MainActor (NovelLaunchContext) -> Void
    var requestManga: @MainActor (MangaLaunchContext) -> Void
}
