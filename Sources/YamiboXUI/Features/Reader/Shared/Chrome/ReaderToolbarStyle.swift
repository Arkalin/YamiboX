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
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
#endif
