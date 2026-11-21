import Foundation
import YamiboXCore

enum ReaderHighlightStyleDefault {
    static func current(in defaults: UserDefaults = .standard) -> LikeStyle {
        guard let raw = defaults.string(forKey: YamiboAppStorageKey.readerDefaultHighlightStyle),
              let style = LikeStyle(rawValue: raw) else {
            return .default
        }
        return style
    }

    static func set(_ style: LikeStyle, in defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: YamiboAppStorageKey.readerDefaultHighlightStyle)
    }
}
