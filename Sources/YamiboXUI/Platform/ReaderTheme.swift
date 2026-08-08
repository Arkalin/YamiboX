import SwiftUI

/// Reader-owned colors. These deliberately do not reference `ForumTheme` so
/// reader presentations remain stable when the forum gains selectable themes.
enum ReaderTheme {
    static let accent = AppColors.accent
    static let progressAccent = Color(light: 0xF59E2A, dark: 0xF0A33A)
    static let chapterCommentAction = Color(light: 0x4E2A1B, dark: 0xD6A083)
    static let chapterCommentRating = Color(light: 0x26705C, dark: 0x5FC9A8)
    static let chapterCommentReply = Color(light: 0x475CAD, dark: 0x8FA0E0)
}
