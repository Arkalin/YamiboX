import Foundation
import YamiboXCore

/// One-shot "scroll one viewport" command for the vertical viewports,
/// deduplicated by `revision` like `MangaNovelReaderViewportPlacement`.
struct ReaderControlScrollStepRequest: Hashable, Sendable {
    var direction: ReaderControlScrollDirection
    var revision: Int
}
