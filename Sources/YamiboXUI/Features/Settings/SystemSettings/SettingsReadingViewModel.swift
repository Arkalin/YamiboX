import Foundation
import Observation
import YamiboXCore

/// State and field-level persistence for the Reading settings page.
@MainActor
@Observable
final class SettingsReadingViewModel: AppSettingsPersisting {
    var novelDownload = NovelDownloadSettings()
    var chapterComments = ChapterCommentFilterSettings()
    var readingProgress = ReadingProgressSettings()
    var readerToolbarStyle = ReaderToolbarStyle.liquidGlass
    var isEditingCommentRule = false
    private(set) var pendingCommentRuleEdits = 0
    let commentFilterEngine = ChapterCommentFilterEngine()
    private let updateSettings: AtomicSettingsUpdater?

    let dependencies: SettingsDependencies
    var settingsStore: SettingsStore { dependencies.settingsStore }
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity,
         updateSettings: AtomicSettingsUpdater? = nil) {
        self.dependencies = dependencies
        self.activity = activity
        self.updateSettings = updateSettings
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        novelDownload = settings.novelDownload
        chapterComments = settings.chapterComments
        readingProgress = settings.readingProgress
        readerToolbarStyle = settings.readerToolbarStyle
    }

    func restoreDefaultsAfterApplicationReset() {
        novelDownload = NovelDownloadSettings()
        chapterComments = ChapterCommentFilterSettings()
        readingProgress = ReadingProgressSettings()
        readerToolbarStyle = .liquidGlass
    }

    func updateSavesNormalThreadProgress(_ enabled: Bool) {
        persistSettings(\.readingProgress.savesNormalThreadProgress, to: enabled, updateSettings: updateSettings) {
            $0.readingProgress.savesNormalThreadProgress = enabled
        }
    }

    func updateReaderToolbarStyle(_ style: ReaderToolbarStyle) {
        guard ReaderToolbarStyle.supportsLiquidGlass else { return }
        persistSettings(\.readerToolbarStyle, to: style, updateSettings: updateSettings) {
            $0.readerToolbarStyle = style
        }
    }

    // MARK: - Novel download

    func updateNovelDownloadRetainsInlineImages(_ retainsInlineImages: Bool) {
        persistSettings(\.novelDownload.retainsInlineImages, to: retainsInlineImages) {
            $0.novelDownload.retainsInlineImages = retainsInlineImages
        }
    }

    func updateNovelDownloadAutoRefreshEnabled(_ isAutoRefreshEnabled: Bool) {
        persistSettings(\.novelDownload.isAutoRefreshEnabled, to: isAutoRefreshEnabled) {
            $0.novelDownload.isAutoRefreshEnabled = isAutoRefreshEnabled
        }
    }

    func setCommentFilterEnabled(_ enabled: Bool, scope: ChapterCommentFilterScope) {
        let keyPath: ReferenceWritableKeyPath<SettingsReadingViewModel, Bool> = scope == .ratings
            ? \.chapterComments.ratings.isEnabled : \.chapterComments.discussions.isEnabled
        persistCommentSetting(keyPath, to: enabled) {
            $0.chapterComments[scope].isEnabled = enabled
        }
    }

    func deleteCommentRules(at offsets: IndexSet, scope: ChapterCommentFilterScope) {
        var rules = chapterComments[scope].rules
        for index in offsets.sorted(by: >) { rules.remove(at: index) }
        persistCommentRules(rules, scope: scope)
    }

    func resetCommentRules(scope: ChapterCommentFilterScope) {
        let defaults = ChapterCommentFilterGroup.defaults(for: scope)
        let keyPath: ReferenceWritableKeyPath<SettingsReadingViewModel, ChapterCommentFilterGroup> = scope == .ratings
            ? \.chapterComments.ratings : \.chapterComments.discussions
        persistCommentSetting(keyPath, to: defaults) {
            $0.chapterComments[scope] = defaults
        }
    }

    func saveCommentRule(_ rule: ChapterCommentFilterRule, scope: ChapterCommentFilterScope) async throws -> Bool {
        try await commentFilterEngine.validate(pattern: rule.pattern)
        var rules = chapterComments[scope].rules
        guard !rules.contains(where: { $0.id != rule.id && $0.pattern == rule.pattern }) else {
            throw ChapterCommentPatternError.duplicate
        }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        return await persistCommentRules(rules, scope: scope).value
    }

    @discardableResult
    private func persistCommentRules(_ rules: [ChapterCommentFilterRule], scope: ChapterCommentFilterScope) -> Task<Bool, Never> {
        let keyPath: ReferenceWritableKeyPath<SettingsReadingViewModel, [ChapterCommentFilterRule]> = scope == .ratings
            ? \.chapterComments.ratings.rules : \.chapterComments.discussions.rules
        return persistCommentSetting(keyPath, to: rules) {
            $0.chapterComments[scope].rules = rules
        }
    }

    @discardableResult
    private func persistCommentSetting<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<SettingsReadingViewModel, Value>, to value: Value,
        mutate: @escaping @Sendable (inout AppSettings) -> Void
    ) -> Task<Bool, Never> {
        pendingCommentRuleEdits += 1
        let operation = persistSettings(keyPath, to: value, updateSettings: updateSettings, mutate: mutate)
        return Task {
            defer { pendingCommentRuleEdits -= 1 }
            return await operation.value
        }
    }

}
