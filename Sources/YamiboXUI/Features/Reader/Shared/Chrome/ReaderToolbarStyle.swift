import SwiftUI
import YamiboXCore

extension ReaderToolbarStyle {
    static var supportsLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var effectiveStyle: Self {
        Self.supportsLiquidGlass ? self : .books
    }
}

extension EnvironmentValues {
    @Entry var readerToolbarStyle: ReaderToolbarStyle = .liquidGlass
    @Entry var readerToolbarPaper: Color = Color(uiColor: .systemBackground)
    @Entry var readerToolbarInk: Color = .primary
}

#if os(iOS)
/// Shared by horizontal and vertical Books progress indicators.
struct ReaderBooksProgressPalette {
    let paper: Color
    let colorScheme: ColorScheme

    var usesDarkPaper: Bool {
        let color = UIColor(paper).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return red * 0.299 + green * 0.587 + blue * 0.114 < 0.5
    }

    var readOverlay: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)
    }

    var unreadOverlay: Color {
        usesDarkPaper ? Color.white.opacity(0.38) : Color.black.opacity(0.85)
    }
}

extension View {
    func readerBooksBackdrop(isVisible: Bool) -> some View {
        background {
            ReaderBooksBackdrop()
                .readerChromeFadeVisibility(isVisible)
        }
    }

    func readerStyledChromePanel(
        cornerRadius: CGFloat = 24,
        tint: Color = .clear,
        isInteractive: Bool = false,
        isDirectory: Bool = false
    ) -> some View {
        modifier(ReaderStyledChromePanel(
            cornerRadius: cornerRadius, tint: tint,
            isInteractive: isInteractive, isDirectory: isDirectory
        ))
    }

    func readerBottomChromeButtonStyle(tint: Color) -> some View {
        modifier(ReaderBottomChromeButtonStyle(tint: tint))
    }

    func readerBooksPressFeedback(isPressed: Bool) -> some View {
        modifier(ReaderBooksPressFeedback(isPressed: isPressed))
    }
}

/// Only changes rendering: control layout and hit targets stay stable while pressed.
private struct ReaderBooksPressFeedback: ViewModifier {
    let isPressed: Bool
    @Environment(\.readerToolbarStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let pressed = isPressed && isEnabled && style.effectiveStyle == .books
        content
            .brightness(pressed ? (colorScheme == .dark ? 0.10 : -0.10) : 0)
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: pressed ? 0.10 : 0.20), value: pressed)
    }
}

/// For controls whose label already contains its panel, unlike the action row.
struct ReaderBooksPressButtonStyle: ButtonStyle {
    var isPressFeedbackEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.readerBooksPressFeedback(isPressed: isPressFeedbackEnabled && configuration.isPressed)
    }
}

private struct ReaderStyledChromePanel: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let isInteractive: Bool
    let isDirectory: Bool
    @Environment(\.readerToolbarStyle) private var style
    @Environment(\.readerToolbarPaper) private var paper
    @Environment(\.readerToolbarInk) private var ink
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if style.effectiveStyle == .books {
            content
                .foregroundStyle(ink)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(paper)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(isDirectory
                                    ? Color.black.opacity(0.80)
                                    : (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)))
                        }
                }
        } else {
            content.readerChromePanel(cornerRadius: cornerRadius, tint: tint, isInteractive: isInteractive)
        }
    }
}

/// One diffuse field behind the whole stack, rather than a shadow on each
/// capsule. Keeping it separate also prevents text and glyphs casting shadows.
private struct ReaderBooksBackdrop: View {
    @Environment(\.readerToolbarStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if style.effectiveStyle == .books {
            RoundedRectangle(cornerRadius: 64, style: .continuous)
                .fill(.black.opacity(colorScheme == .dark ? 0.42 : 0.26))
                .padding(-36)
                .blur(radius: 64)
                .offset(y: 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ReaderBottomChromeButtonStyle: ViewModifier {
    let tint: Color
    @Environment(\.readerToolbarStyle) private var style

    func body(content: Content) -> some View {
        if style.effectiveStyle == .books {
            content.buttonStyle(ReaderBooksButtonStyle())
        } else {
            content.readerChromeButtonStyle(tint: tint)
        }
    }
}

private struct ReaderBooksButtonStyle: ButtonStyle {
    @Environment(\.readerToolbarInk) private var ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .padding(.vertical, 7)
            .readerStyledChromePanel()
            .readerBooksPressFeedback(isPressed: configuration.isPressed)
    }
}
#endif
