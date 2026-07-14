import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct ReaderGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func readerChromePanel(cornerRadius: CGFloat = 28, tint: Color = .clear) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func readerChromeButtonStyle(prominent: Bool = false, tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self
                    .buttonStyle(.glassProminent)
                    .tint(tint)
            } else {
                self
                    .buttonStyle(.glass)
                    .tint(tint)
            }
        } else {
            if prominent {
                self
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            } else {
                self
                    .buttonStyle(.bordered)
                    .tint(tint)
            }
        }
    }

    func readerChromeFadeVisibility(_ isVisible: Bool) -> some View {
        modifier(ReaderChromeFadeVisibilityModifier(isVisible: isVisible))
    }

    func readerChromeAnchoredPopupVisibility(_ isVisible: Bool) -> some View {
        modifier(ReaderChromeAnchoredPopupVisibilityModifier(isVisible: isVisible))
    }
}

private struct ReaderChromeFadeVisibilityModifier: ViewModifier {
    let isVisible: Bool
    private let presentation = ReaderChromeVisibilityAnimationPresentation.fade

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(.easeInOut(duration: presentation.duration), value: isVisible)
    }
}

private struct ReaderChromeAnchoredPopupVisibilityModifier: ViewModifier {
    let isVisible: Bool
    private let presentation = ReaderChromeVisibilityAnimationPresentation.anchoredPopup

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                isVisible ? 1 : presentation.hiddenScale,
                anchor: presentation.anchor?.unitPoint ?? .bottomTrailing
            )
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(.easeInOut(duration: presentation.duration), value: isVisible)
    }
}

private extension ReaderChromePopupAnchor {
    var unitPoint: UnitPoint {
        switch self {
        case .bottomTrailing:
            return .bottomTrailing
        }
    }
}

struct ReaderChromeIconButton: View {
    let systemName: String
    let title: String
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 34, height: 34)
        }
        .readerChromeButtonStyle(tint: readerChromeButtonTint(for: colorScheme))
        .opacity(isEnabled ? 1 : 0.34)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

struct ReaderChromeCircleButton: View {
    let systemName: String
    let title: String
    var tint: Color
    var prominent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 34, height: 34)
        }
        .buttonBorderShape(.circle)
        .readerChromeButtonStyle(prominent: prominent, tint: tint)
        .opacity(isEnabled ? 1 : 0.34)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

enum ReaderChromeHistoryDirection {
    case back
    case forward
}

struct ReaderChromeHistoryButton: View {
    let direction: ReaderChromeHistoryDirection
    let title: String
    var isGlassBacked = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private static let hitTargetSize: CGFloat = 44
    private let iconSize: CGFloat = 19
    private let glassSize: CGFloat = 27

    var body: some View {
        Button(action: action) {
            icon
                .modifier(ReaderChromeHistoryButtonGlassModifier(
                    isGlassBacked: isGlassBacked,
                    size: glassSize,
                    tint: readerChromePanelTint(for: colorScheme)
                ))
                .frame(width: Self.hitTargetSize, height: Self.hitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    static func controlSize(isGlassBacked: Bool) -> CGFloat {
        hitTargetSize
    }

    private var icon: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(symbolColor, fillColor)
            .font(.headline)
            .frame(width: iconSize, height: iconSize)
    }

    private var systemName: String {
        switch direction {
        case .back:
            "arrow.uturn.backward.circle.fill"
        case .forward:
            "arrow.uturn.forward.circle.fill"
        }
    }

    private var fillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.86) : Color(red: 0.20, green: 0.16, blue: 0.12)
    }

    private var symbolColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.82) : Color(red: 0.96, green: 0.90, blue: 0.80)
    }
}

private struct ReaderChromeHistoryButtonGlassModifier: ViewModifier {
    let isGlassBacked: Bool
    let size: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        if isGlassBacked {
            content
                .frame(width: size, height: size)
                .readerChromePanel(cornerRadius: size / 2, tint: tint)
        } else {
            content
        }
    }
}

struct ReaderChromeCapsuleButton: View {
    let title: String
    let systemName: String
    var isEnabled = true
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()
        let controlTint = layout.progressCapsulesUseButtonTint
            ? readerChromeButtonTint(for: colorScheme)
            : Color.accentColor

        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 12)
                Image(systemName: systemName)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(layout.directoryCapsuleContentUsesAccentColor ? controlTint : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: layout.progressPanelHeight)
            .padding(.horizontal, 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .readerChromePanel(cornerRadius: 24, tint: readerChromePanelTint(for: colorScheme))
        .opacity(isEnabled ? 1 : 0.34)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

struct ReaderToolbarIconButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(title)
    }
}

func readerChromePanelTint(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.18)
}

func readerChromeButtonTint(for colorScheme: ColorScheme) -> Color {
    .accentColor
}

/// Reader Preview Mode indicator: shown in the top chrome of both the novel
/// and manga readers while `NovelLaunchContext`/`MangaLaunchContext.isPreview`
/// is true, so the user knows reading progress isn't being recorded. See
/// Reader Preview Mode in docs/contexts/reader-navigation/CONTEXT.md.
struct ReaderPreviewModeBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
            Text(L10n.string("reader.preview_mode"))
                .fontWeight(.semibold)
            Text("·")
                .foregroundStyle(.secondary)
            Text(L10n.string("reader.preview_mode_hint"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .readerChromePanel(cornerRadius: 14, tint: readerChromePanelTint(for: colorScheme))
    }
}
#endif
