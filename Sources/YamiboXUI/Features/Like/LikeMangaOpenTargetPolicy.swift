import Foundation
import YamiboXCore

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
            directoryName: isSmartModeEnabled ? workTitle : nil,
            directoryID: isSmartModeEnabled ? MangaDirectoryID(rawValue: workID) : nil,
            isPreview: true,
            isSmartModeEnabled: isSmartModeEnabled,
            forumID: anchor.forumID
        )
    }
}
