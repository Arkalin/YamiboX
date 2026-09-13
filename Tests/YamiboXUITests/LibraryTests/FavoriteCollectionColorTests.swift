import SwiftUI
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor
@Suite struct FavoriteCollectionColorTests {
    @Test func customColorsRoundTripThroughSystemPicker() {
        for expected in [
            FavoriteCollectionColor.custom(red: 0, green: 0, blue: 0),
            .custom(red: 255, green: 255, blue: 255),
            .custom(red: 18, green: 171, blue: 239)
        ] {
            var actual = FavoriteCollectionColor.gray
            actual.setSwiftUIColor(expected.swiftUIColor)
            #expect(actual == expected)
        }
    }

    @Test func extendedComponentsAreClampedAndOpacityIsIgnored() {
        var color = FavoriteCollectionColor.gray
        color.setSwiftUIColor(Color(.sRGB, red: -0.1, green: 0.5, blue: 1.2, opacity: 0.3))
        #expect(color == .custom(red: 0, green: 128, blue: 255))
    }
}
