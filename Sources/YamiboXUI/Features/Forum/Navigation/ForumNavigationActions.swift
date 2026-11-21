import Foundation
import YamiboXCore

@MainActor
struct ForumNavigationActions {
    var accountGeneration: @MainActor () -> UUID
    var presentNovel: @MainActor (NovelLaunchContext) -> Void
    var requestManga: @MainActor (MangaLaunchContext) -> Void
}
