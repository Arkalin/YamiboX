import Foundation
import YamiboXCore

/// The reader's sticky "last style I chose", used for the next annotation.
///
/// Global rather than per-work, matching Apple Books: a reader's colour
/// semantics stay stable across books, and resetting per work would break the
/// habit every time they start a new one.
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
