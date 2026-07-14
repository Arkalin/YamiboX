import SwiftUI
import YamiboXCore
import UIKit

enum YamiboColors {
    enum Site {
        static let brownDeep = Color(light: 0x4E2A1B, dark: 0x24120C)
        static let brownPrimary = Color(light: 0x6D3A2B, dark: 0xD6A083)
        static let brownEmphasis = Color(light: 0x4E2A1B, dark: 0xD6A083)
        static let brownLight = Color(light: 0xCCB8A8, dark: 0x8F6F5E)
        static let creamBackground = Color(light: 0xFFF3D6, dark: 0x17110D)
        static let creamSurface = Color(light: 0xFFF7E0, dark: 0x241B15)
        static let orangeAccent = Color(light: 0xF59E2A, dark: 0xF0A33A)
        static let textDark = Color(light: 0x2E1A0E, dark: 0xF4E7D1)
        static let htmlTextDark = Color(light: 0x6E2B19, dark: 0xF0D8BC)
        /// Light variant deepened from 0xFF5656: as caption text on the 12%
        /// red-tinted cream badge that value measured ~2.6:1; 0xA61B29 clears
        /// 4.5:1 in every current usage (badge text, header stat text, and
        /// as a fill under white text). The dark variant already passes.
        static let redAccent = Color(light: 0xA61B29, dark: 0xFF7A70)
        /// Chapter-comment source badge accents (ratingReason/reply). Light
        /// values match the badge's original fixed RGB, which read fine
        /// against a light background; the dark variants are lightened from
        /// that same fixed RGB, which measured ~2.8:1 as badge text against
        /// secondarySystemGroupedBackground in dark mode. These clear 4.5:1.
        static let ratingReasonAccent = Color(light: 0x26705C, dark: 0x5FC9A8)
        static let replyAccent = Color(light: 0x475CAD, dark: 0x8FA0E0)
        static let pinnedBackground = Color(light: 0xFFF0C8, dark: 0x302416)
        static let announcementBackground = Color(light: 0xFFE8B0, dark: 0x382711)
        static let navBarBackground = Color(light: 0xFFE6B7, dark: 0x21150F)
        static let navBarIconUnselected = Color(light: 0xD29D7C, dark: 0xA97B63)

        static let border = brownPrimary.opacity(0.18)
        static let secondaryText = brownPrimary.opacity(0.68)
        static let tertiaryText = brownLight
        static let mutedFill = brownPrimary.opacity(0.10)
        static let accentFill = orangeAccent.opacity(0.15)

        static let creamBackgroundUIColor = UIColor(hex: 0xFFF3D6)
        static let creamBackgroundDarkUIColor = UIColor(hex: 0x17110D)

        static func navigationBarBackground(for colorScheme: ColorScheme) -> Color {
            switch colorScheme {
            case .dark:
                Color(hex: 0x24120C)
            case .light:
                Color(hex: 0x4E2A1B)
            @unknown default:
                Color(hex: 0x4E2A1B)
            }
        }
    }

    enum SystemSurface {
        static var background: Color {
            Color(uiColor: .systemBackground)
        }

        static var groupedBackground: Color {
            Color(uiColor: .systemGroupedBackground)
        }

        static var secondaryGroupedBackground: Color {
            Color(uiColor: .secondarySystemGroupedBackground)
        }

        static var selectionBarBackground: Color {
            Color(uiColor: .systemGray6)
        }
    }
}

typealias ForumColors = YamiboColors.Site

extension View {
    func forumPageBackground() -> some View {
        background(ForumColors.creamBackground.ignoresSafeArea())
    }

    func forumNavigationBarStyle() -> some View {
        modifier(ForumNavigationBarStyleModifier())
    }

    func forumCardBackground(
        cornerRadius: CGFloat = 8,
        fill: Color = ForumColors.creamSurface
    ) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ForumColors.border, lineWidth: 1)
            }
    }
}

private struct ForumNavigationBarStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(ForumColors.navigationBarBackground(for: colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension FavoriteTagColor {
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    var iconTextColor: Color {
        relativeLuminance > 0.52 ? .black : .white
    }

    private var relativeLuminance: Double {
        let components: (red: Double, green: Double, blue: Double) = switch self {
        case .red: (1.00, 0.23, 0.19)
        case .orange: (1.00, 0.58, 0.00)
        case .yellow: (1.00, 0.80, 0.00)
        case .green: (0.20, 0.78, 0.35)
        case .blue: (0.00, 0.48, 1.00)
        case .purple: (0.69, 0.32, 0.87)
        case .pink: (1.00, 0.18, 0.33)
        case .gray: (0.56, 0.56, 0.58)
        }

        return 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
    }
}

extension Color {
    init(light lightHex: UInt32, dark darkHex: UInt32) {
        self.init(uiColor: UIColor { traitCollection in
            UIColor(hex: traitCollection.userInterfaceStyle == .dark ? darkHex : lightHex)
        })
    }

    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
