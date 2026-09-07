import Foundation
import Testing
@testable import YamiboXCore

@Suite struct FavoriteItemTapActionTests {
    @Test func defaultsToDetailsForNewAndLegacySettings() throws {
        #expect(FavoriteLibrarySettings().itemTapAction == .detail)
        let legacy = try JSONDecoder().decode(FavoriteLibrarySettings.self, from: Data("{}".utf8))
        #expect(legacy.itemTapAction == .detail)
    }

    @Test(arguments: FavoriteItemTapAction.allCases)
    func roundTripsPreferenceWithoutChangingOtherSettings(_ action: FavoriteItemTapAction) throws {
        let settings = FavoriteLibrarySettings(layoutMode: .staggered, sortDescending: true, itemTapAction: action)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(FavoriteLibrarySettings.self, from: data) == settings)
    }
}
