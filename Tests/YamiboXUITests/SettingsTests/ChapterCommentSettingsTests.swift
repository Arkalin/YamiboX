import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ChapterCommentSettingsTests: XCTestCase {
    func testAddEditDeleteResetAndReloadPreserveOtherSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        let root = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await root.load()
        let model = root.reading
        let rule = ChapterCommentFilterRule(id: "custom", pattern: "(?i)spam")
        let saved = try await model.saveCommentRule(rule, scope: .discussions)
        XCTAssertTrue(saved)
        model.setCommentFilterEnabled(true, scope: .discussions)
        try await waitForSettings { model.pendingCommentRuleEdits == 0 }
        try await fixture.settingsStore.update { $0.novelOfflineCache.retainsInlineImages = true }

        let edited = ChapterCommentFilterRule(id: rule.id, pattern: "广告")
        let editedSaved = try await model.saveCommentRule(edited, scope: .discussions)
        XCTAssertTrue(editedSaved)
        model.deleteCommentRules(at: IndexSet(0..<8), scope: .ratings)
        try await waitForSettings { model.pendingCommentRuleEdits == 0 }

        let reopened = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await reopened.load()
        XCTAssertTrue(reopened.reading.chapterComments.ratings.rules.isEmpty)
        XCTAssertEqual(reopened.reading.chapterComments.discussions.rules, [edited])
        XCTAssertTrue(reopened.reading.chapterComments.discussions.isEnabled)
        XCTAssertTrue(reopened.reading.novelOfflineCache.retainsInlineImages)

        reopened.reading.resetCommentRules(scope: .ratings)
        try await waitForSettings { reopened.reading.pendingCommentRuleEdits == 0 }
        XCTAssertEqual(reopened.reading.chapterComments.ratings, .defaults(for: .ratings))
        XCTAssertEqual(reopened.reading.chapterComments.discussions.rules, [edited])
        reopened.reading.resetCommentRules(scope: .discussions)
        try await waitForSettings { reopened.reading.pendingCommentRuleEdits == 0 }
        XCTAssertEqual(reopened.reading.chapterComments, .init())
        model.restoreDefaultsAfterApplicationReset()
        XCTAssertEqual(model.chapterComments, .init())
    }

    func testInvalidAndDuplicateRulesAreNotSavedButOtherGroupCanReusePattern() async throws {
        let fixture = try makeSystemSettingsFixture()
        let model = SettingsReadingViewModel(dependencies: fixture.appContext.settingsDependencies, activity: .init())
        for pattern in [" ", "[", #"\A我很赞同\z"#] {
            do {
                _ = try await model.saveCommentRule(.init(pattern: pattern), scope: .ratings)
                XCTFail("Expected rejected pattern: \(pattern)")
            } catch {}
        }
        XCTAssertEqual(model.chapterComments, .init())
        let rule = ChapterCommentFilterRule(pattern: #"\A我很赞同\z"#)
        let saved = try await model.saveCommentRule(rule, scope: .discussions)
        XCTAssertTrue(saved)
        let savedAgain = try await model.saveCommentRule(rule, scope: .discussions)
        XCTAssertTrue(savedAgain)
        XCTAssertEqual(model.chapterComments.discussions.rules, [rule])
    }

    func testFailedSaveToggleDeleteAndResetRollBack() async throws {
        let fixture = try makeSystemSettingsFixture()
        let model = SettingsReadingViewModel(dependencies: fixture.appContext.settingsDependencies, activity: .init(),
                                             updateSettings: { _ in throw YamiboError.underlying("Storage unavailable") })
        let draft = ChapterCommentFilterRule(pattern: "draft")
        let saved = try await model.saveCommentRule(draft, scope: .discussions)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.chapterComments.discussions.rules.isEmpty)
        XCTAssertEqual(model.errorMessage, "Storage unavailable")
        model.setCommentFilterEnabled(false, scope: .ratings)
        try await waitForSettings { model.pendingCommentRuleEdits == 0 }
        XCTAssertTrue(model.chapterComments.ratings.isEnabled)
        model.deleteCommentRules(at: IndexSet(integer: 0), scope: .ratings)
        try await waitForSettings { model.pendingCommentRuleEdits == 0 }
        XCTAssertEqual(model.chapterComments.ratings.rules.count, 8)
        model.chapterComments.discussions = .init(isEnabled: true, rules: [draft])
        model.resetCommentRules(scope: .discussions)
        try await waitForSettings { model.pendingCommentRuleEdits == 0 }
        XCTAssertEqual(model.chapterComments.discussions, .init(isEnabled: true, rules: [draft]))
    }
}
