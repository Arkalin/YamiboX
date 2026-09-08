import Foundation
import Testing
@testable import YamiboXCore

@Suite("Reading animation persistence")
struct ReaderPagedTurnStyleTests {
    @Test(arguments: ReaderPagedTurnStyle.allCases)
    func settingsStorePreservesAnimationIndependently(style: ReaderPagedTurnStyle) async throws {
        let suite = "reader-animation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(
            novelReader: NovelReaderAppearanceSettings(readingMode: .vertical, pagedTurnStyle: style),
            manga: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .none)
        )
        let store = SettingsStore(defaults: defaults, key: "settings")
        try await store.save(settings)
        #expect(await store.load() == settings)
    }

    @Test func existingWireValuesAndDefaultsAreUnchanged() throws {
        for style in ReaderPagedTurnStyle.allCases {
            let data = Data("\"\(style.rawValue)\"".utf8)
            #expect(try JSONDecoder().decode(ReaderPagedTurnStyle.self, from: data) == style)
            #expect(try JSONEncoder().encode(style) == data)
        }
        #expect(ReaderPagedTurnStyle.allCases == [.none, .slide, .pageCurl, .quickFade])
        #expect(NovelReaderAppearanceSettings().readingMode == .paged)
        #expect(MangaReaderSettings().readingMode == .vertical)
        #expect(NovelReaderAppearanceSettings().pagedTurnStyle == .slide)
        #expect(MangaReaderSettings().pagedTurnStyle == .slide)
    }
}
