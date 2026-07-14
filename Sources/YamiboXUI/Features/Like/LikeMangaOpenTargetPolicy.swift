import Foundation
import YamiboXCore

/// Builds the manga-reader launch context for opening a liked manga image,
/// following the board's *current* 阅读方式 configuration (pluggable-reader-
/// config R13, the likes-side counterpart of the favorites dispatch R11):
///
/// - Anchor carries a board fid (captured from the reader's launch context):
///   the smart bit is the live `isSmartComicModeEnabled(forumID:)` answer —
///   one rule, no special cases. A board currently manga+smart opens with
///   directory context; manga-off/novel/普通/unconfigured all open the
///   anchored chapter as a single mode-off thread. The reader type itself
///   stays manga regardless of the mode — a page-image anchor can only be
///   displayed by the manga reader.
/// - Anchor has no fid (rows captured before the field existed, or a reader
///   launched without board context): pre-R13 behavior — smart mode assumed
///   on, matching the capture-time invariant that liked manga images could
///   only come from a mode-on read (decision #12).
enum LikeMangaOpenTargetPolicy {
    static func launchContext(
        anchor: MangaImageLikeAnchor,
        workID: String,
        workTitle: String,
        boardReader: BoardReaderSettings
    ) -> MangaLaunchContext {
        let isSmartModeEnabled: Bool
        if anchor.forumID != nil {
            isSmartModeEnabled = boardReader.isSmartComicModeEnabled(forumID: anchor.forumID)
        } else {
            isSmartModeEnabled = true
        }
        return MangaLaunchContext(
            originalThreadID: anchor.chapterTID,
            chapterTID: anchor.chapterTID,
            displayTitle: workTitle,
            source: .like,
            initialPage: anchor.pageLocalIndex,
            // Mode-off launches never carry a directory name (mirroring the
            // favorites resolver's single-thread track).
            directoryName: isSmartModeEnabled ? workID : nil,
            isPreview: true,
            isSmartModeEnabled: isSmartModeEnabled,
            forumID: anchor.forumID
        )
    }
}
