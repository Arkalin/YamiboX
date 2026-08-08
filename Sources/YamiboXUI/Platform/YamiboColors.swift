import SwiftUI
import YamiboXCore
import UIKit

enum YamiboColors {
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
