import SwiftUI

/// Colors owned by the app shell rather than any feature area.
enum AppColors {
    /// The target's adaptive AccentColor asset. Keeping this separate from
    /// `ForumTheme` lets the forum change theme without recoloring readers,
    /// settings, or other app-level presentations.
    static let accent = Color("AccentColor", bundle: .main)
}
