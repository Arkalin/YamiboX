import Foundation
import Testing
@testable import YamiboXCore

// Effective display/open category (pluggable-reader-config R13): a configured
// board entry dictates the category regardless of the recorded identity; a
// board with no entry (never configured, or the row carries no fid) falls
// back to the stored identity-derived category.
@Suite("HistoryTests: Browsing History Entry Effective Category")
struct BrowsingHistoryEntryCategoryTests {
    @Test func configuredEntryOverridesRecordedIdentity() {
        var boardReader = BoardReaderSettings(entries: [:])
        boardReader.setEntry(.init(mode: .novel), forumID: "40")

        let normalRecorded = BrowsingHistoryEntry(
            target: .normalThread(threadID: "901"),
            title: "配置前读过的帖子",
            forumID: "40"
        )
        #expect(normalRecorded.category == .normal)
        #expect(normalRecorded.category(boardReader: boardReader) == .novel)

        boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "40")
        #expect(normalRecorded.category(boardReader: boardReader) == .manga)

        // An explicit 普通 entry (R12) maps to .normal even for rows recorded
        // under another identity.
        boardReader.setEntry(.init(mode: .normal), forumID: "40")
        let novelRecorded = BrowsingHistoryEntry(
            target: .novelThread(threadID: "902"),
            title: "改回普通板块的小说行",
            forumID: "40"
        )
        #expect(novelRecorded.category(boardReader: boardReader) == .normal)
    }

    @Test func missingEntryOrForumIDFallsBackToRecordedIdentity() {
        let boardReader = BoardReaderSettings(entries: [:])

        let novelRow = BrowsingHistoryEntry(
            target: .novelThread(threadID: "903"),
            title: "未配置板块的小说行",
            forumID: "88"
        )
        #expect(novelRow.category(boardReader: boardReader) == .novel)

        let mangaRowWithoutFid = BrowsingHistoryEntry(
            target: .mangaTitle(mangaID: "m1", cleanBookName: "无fid漫画"),
            title: "无fid漫画"
        )
        #expect(mangaRowWithoutFid.category(boardReader: boardReader) == .manga)
    }
}
