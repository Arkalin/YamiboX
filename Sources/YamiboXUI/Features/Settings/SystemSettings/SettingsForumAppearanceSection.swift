import SwiftUI
import UIKit
import YamiboXCore

struct SettingsForumAppearanceSection: View {
    let selectedPreset: ForumThemePreset
    let isBusy: Bool
    let onSelect: (ForumThemePreset) -> Void

    var body: some View {
        Section {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(ForumThemePreset.allCases) { preset in
                        Button {
                            onSelect(preset)
                        } label: {
                            ForumThemePreviewCard(
                                preset: preset,
                                isSelected: selectedPreset == preset
                            )
                        }
                        .buttonStyle(PressableCardStyle(pressedScale: 0.98))
                        .disabled(isBusy)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            Text(L10n.string("settings.section.appearance"))
        }
    }
}

private struct ForumThemePreviewCard: View {
    let preset: ForumThemePreset
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: ForumTheme {
        .theme(for: preset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForumThemeMiniPreview(theme: theme)

            Text(preset.settingsTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .padding(10)
        .frame(width: 144, height: 136, alignment: .topLeading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? AppColors.accent : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColors.accent)
                    .background(Color(uiColor: .systemBackground), in: Circle())
                    .padding(6)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.settingsTitle)
        .accessibilityValue(isSelected ? L10n.string("common.current") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ForumThemeMiniPreview: View {
    let theme: ForumTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 7, height: 7)
                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: 36, height: 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(theme.navigationBarBackground(for: colorScheme))

            VStack(spacing: 0) {
                ForumThemeMiniRow(theme: theme, lineWidth: 58)
                Rectangle()
                    .fill(theme.divider)
                    .frame(height: 1)
                ForumThemeMiniRow(theme: theme, lineWidth: 42)
            }
            .padding(.horizontal, 8)
            .background(theme.pageBackground)
        }
        .frame(width: 124, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }
}

private struct ForumThemeMiniRow: View {
    let theme: ForumTheme
    let lineWidth: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(theme.mutedAccent)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 4) {
                Capsule()
                    .fill(theme.primaryText)
                    .frame(width: lineWidth, height: 4)
                Capsule()
                    .fill(theme.secondaryText)
                    .frame(width: lineWidth * 0.72, height: 3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(theme.surface)
    }
}

private extension ForumThemePreset {
    var settingsTitle: String {
        switch self {
        case .standard: L10n.string("settings.forum_theme.standard")
        case .classic: L10n.string("settings.forum_theme.classic")
        case .teal: L10n.string("settings.forum_theme.teal")
        case .rose: L10n.string("settings.forum_theme.rose")
        }
    }
}
