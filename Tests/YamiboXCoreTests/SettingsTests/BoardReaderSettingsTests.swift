import Foundation
import Testing
@testable import YamiboXCore

// Pluggable-reader-config decisions #1/#4/#8: any board is configurable, the
// factory default carries over the old hardcoded taxonomy (49/55/60 novel,
// 30/46/37 manga, smart bit on only for 30), and the smart query follows one
// rule with no special cases.
@Suite("SettingsTests: Board Reader Settings")
struct BoardReaderSettingsTests {
    @Test func defaultInitIsFactoryDefault() {
        let settings = BoardReaderSettings()
        #expect(settings == BoardReaderSettings.factoryDefault)
        #expect(settings.entries.count == 6)
        #expect(settings.entry(forumID: "49")?.mode == .novel)
        #expect(settings.entry(forumID: "55")?.mode == .novel)
        #expect(settings.entry(forumID: "60")?.mode == .novel)
        #expect(settings.entry(forumID: "30")?.mode == .manga(smartEnabled: true))
        #expect(settings.entry(forumID: "46")?.mode == .manga(smartEnabled: false))
        #expect(settings.entry(forumID: "37")?.mode == .manga(smartEnabled: false))
        // Every factory-default board carries a verified name snapshot
        // resolved from yamibo-api's `YamiboConstant.kt`.
        #expect(settings.entry(forumID: "49")?.boardName == "文學區")
        #expect(settings.entry(forumID: "55")?.boardName == "轻小说/译文区")
        #expect(settings.entry(forumID: "60")?.boardName == "TXT小说区")
        #expect(settings.entry(forumID: "30")?.boardName == "中文百合漫画区")
        #expect(settings.entry(forumID: "46")?.boardName == "原创图作区")
        #expect(settings.entry(forumID: "37")?.boardName == "百合漫画图源区")
    }

    @Test func smartQueryFollowsOneRuleWithNoSpecialCases() {
        let settings = BoardReaderSettings()
        // Only "configured as manga AND smart bit on" reports true.
        #expect(settings.isSmartComicModeEnabled(forumID: "30") == true)
        // Manga with smart off.
        #expect(settings.isSmartComicModeEnabled(forumID: "46") == false)
        #expect(settings.isSmartComicModeEnabled(forumID: "37") == false)
        // Novel boards.
        #expect(settings.isSmartComicModeEnabled(forumID: "49") == false)
        // Unconfigured board, nil and blank fids.
        #expect(settings.isSmartComicModeEnabled(forumID: "999999") == false)
        #expect(settings.isSmartComicModeEnabled(forumID: nil) == false)
        #expect(settings.isSmartComicModeEnabled(forumID: "  ") == false)
        // Trimmed lookup still matches.
        #expect(settings.isSmartComicModeEnabled(forumID: " 30 ") == true)
    }

    @Test func threadKindClassifiesFromConfiguredEntries() {
        let settings = BoardReaderSettings()
        #expect(settings.threadKind(forumID: "49") == .novel)
        #expect(settings.threadKind(forumID: "55") == .novel)
        #expect(settings.threadKind(forumID: "30") == .manga)
        // The smart bit never affects classification.
        #expect(settings.threadKind(forumID: "46") == .manga)
        #expect(settings.threadKind(forumID: "999999") == .unknown)
        #expect(settings.threadKind(forumID: nil) == .unknown)
        #expect(settings.threadKind(forumID: "  ") == .unknown)
    }

    // An explicit `.normal` entry (R12) classifies and reports smart exactly
    // like an unconfigured board — its sole behavioral difference lives in
    // the favorites open dispatch, which checks entry existence itself.
    @Test func explicitNormalEntryClassifiesLikeUnconfiguredBoard() throws {
        var settings = BoardReaderSettings()
        settings.setEntry(.init(mode: .normal, boardName: "改回普通的板块"), forumID: "46")
        #expect(settings.threadKind(forumID: "46") == .unknown)
        #expect(settings.isSmartComicModeEnabled(forumID: "46") == false)
        // The entry itself survives with its name snapshot (it is NOT a
        // removal) and round-trips through Codable.
        #expect(settings.entry(forumID: "46") == .init(mode: .normal, boardName: "改回普通的板块"))
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BoardReaderSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func hasAnySmartEnabledBoardIsPurelyAConfigurationCheck() {
        var settings = BoardReaderSettings()
        #expect(settings.hasAnySmartEnabledBoard == true)
        settings.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "30")
        #expect(settings.hasAnySmartEnabledBoard == false)
        settings.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        #expect(settings.hasAnySmartEnabledBoard == true)
        settings = BoardReaderSettings(entries: [:])
        #expect(settings.hasAnySmartEnabledBoard == false)
    }

    @Test func entryMutationsTrimAndIgnoreBlankForumIDs() {
        var settings = BoardReaderSettings(entries: [:])
        settings.setEntry(.init(mode: .novel, boardName: "文学区"), forumID: " 60 ")
        #expect(settings.entry(forumID: "60")?.mode == .novel)
        #expect(settings.entry(forumID: "60")?.boardName == "文学区")

        settings.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "  ")
        settings.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: nil)
        #expect(settings.entries.count == 1)

        settings.removeEntry(forumID: " 60 ")
        #expect(settings.entry(forumID: "60") == nil)
        #expect(settings.entries.isEmpty)
    }

    @Test func codableRoundTripPreservesEntries() throws {
        var settings = BoardReaderSettings()
        settings.setEntry(.init(mode: .manga(smartEnabled: true), boardName: "自定义板块"), forumID: "77")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BoardReaderSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func appSettingsConvenienceDelegatesToBoardReader() {
        var appSettings = AppSettings()
        #expect(appSettings.isSmartComicModeEnabled(forumID: "30") == true)
        #expect(appSettings.isSmartComicModeEnabled(forumID: "46") == false)
        appSettings.boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        #expect(appSettings.isSmartComicModeEnabled(forumID: "46") == true)
    }

    @Test func placeholderKeyLocalizesWithForumIDSubstitution() {
        #expect(L10n.string("settings.board_reader.board_placeholder", "999") == "板块 999")
    }
}
