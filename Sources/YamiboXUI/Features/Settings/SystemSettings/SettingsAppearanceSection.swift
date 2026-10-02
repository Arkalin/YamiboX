import SwiftUI
import UIKit
import YamiboXCore

struct SettingsAppearanceSection: View {
    let library: AppThemeLibrary
    @Binding var usesAccentSurfaces: Bool
    let isBusy: Bool
    let onSelect: (String) -> Void
    let save: (AppThemeDefinition) async throws -> Void
    let delete: (String) async throws -> Void
    @State private var editingTheme: AppThemeDefinition?

    private var previewTheme: ForumTheme {
        .theme(for: AppAppearanceSettings(
            themeLibrary: library,
            usesAccentSurfaces: usesAccentSurfaces
        ))
    }

    var body: some View {
        Section {
            VStack(spacing: 18) {
                ForumThemePreview(theme: previewTheme)
                    // Keep the illustrative sample compact; the actual controls
                    // below continue to follow the full accessibility text size.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.string("settings.app_theme.preview"))
                    .accessibilityValue(library.selectedTheme?.name ?? L10n.string("settings.app_theme.default"))

                HStack(spacing: 12) {
                    Text(L10n.string("settings.app_theme.my_themes"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let theme = library.selectedTheme, !theme.isBuiltIn {
                        Button {
                            editingTheme = theme
                        } label: {
                            Text(L10n.string("common.edit"))
                                .font(.subheadline)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(L10n.string("settings.app_theme.edit"))
                    }
                    Button {
                        editingTheme = AppThemeDefinition(
                            name: L10n.string("settings.app_theme.untitled"),
                            colorHex: AppAppearanceSettings.defaultCustomThemeColorHex
                        )
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.tint.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel(L10n.string("settings.app_theme.add"))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                AppThemeChoices(library: library, onSelect: onSelect, onEdit: { editingTheme = $0 })
                    .disabled(isBusy)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
            .sheet(item: $editingTheme) { theme in
                AppThemeEditor(
                    initial: theme,
                    isNew: !library.themes.contains { $0.id == theme.id },
                    usesAccentSurfaces: usesAccentSurfaces,
                    save: save,
                    delete: delete
                )
            }

            AppThemeSwitch(L10n.string("settings.app_theme.tint_interface"), isOn: $usesAccentSurfaces)
                .disabled(isBusy)
        } header: {
            Text(L10n.string("settings.app_theme"))
        } footer: {
            Text(L10n.string("settings.app_theme.tint_footer"))
        }
    }

}

private struct AppThemeChoices: View {
    let library: AppThemeLibrary
    let onSelect: (String) -> Void
    let onEdit: (AppThemeDefinition) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            AppThemeChoiceList(library: library, isVertical: true, onSelect: onSelect, onEdit: onEdit)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    AppThemeChoiceList(library: library, isVertical: false, onSelect: onSelect, onEdit: onEdit)
                        .padding(2)
                }
                .scrollIndicators(.hidden)
                .onChange(of: library.selectedID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct AppThemeChoiceList: View {
    let library: AppThemeLibrary
    let isVertical: Bool
    let onSelect: (String) -> Void
    let onEdit: (AppThemeDefinition) -> Void

    var body: some View {
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            ForEach(library.themes) { theme in
                Button {
                    onSelect(theme.id)
                } label: {
                    AppThemeChoice(theme: theme, isSelected: library.selectedID == theme.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(library.selectedID == theme.id ? .isSelected : [])
                .accessibilityActions {
                    if !theme.isBuiltIn {
                        Button(L10n.string("common.edit")) { onEdit(theme) }
                    }
                }
                .id(theme.id)
            }
        }
    }
}

private struct AppThemeChoice: View {
    let theme: AppThemeDefinition
    let isSelected: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var accent: Color {
        AppTheme.theme(for: AppAppearanceSettings(themeLibrary: AppThemeLibrary(themes: [theme], selectedID: theme.id))).controlAccent
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 28, height: 28)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .accessibilityHidden(true)
                    }
                }
            Text(theme.name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 240, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(isSelected ? accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? accent : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
    }
}

/// Uses the same resolved palette as the forum, not a separately styled mock.
struct ForumThemePreview: View {
    let theme: ForumTheme
    @Environment(\.colorScheme) private var colorScheme

    private var navigationForeground: Color {
        theme.usesColoredNavigationBar ? .white : theme.primaryText
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left")
                Spacer()
                Text(L10n.string("settings.app_theme.preview"))
                Spacer()
                Image(systemName: "magnifyingglass")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(navigationForeground)
            .padding(14)
            .background(theme.usesColoredNavigationBar ? theme.navigationBarBackground(for: colorScheme) : theme.pageBackground)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill")
                        .font(.title3)
                        .foregroundStyle(theme.accentText)
                        .frame(width: 40, height: 44)
                        .background(theme.mutedFill, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.string("settings.app_theme.preview_title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Text(L10n.string("settings.app_theme.preview_subtitle"))
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                Rectangle()
                    .fill(theme.divider)
                    .frame(height: 0.5)
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                    Text(L10n.string("settings.app_theme.preview_detail"))
                    Spacer(minLength: 4)
                    Image(systemName: "heart")
                        .foregroundStyle(theme.accentText)
                }
                .font(.caption)
                .foregroundStyle(theme.supportingText)
            }
            .padding(14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .background(theme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.border, lineWidth: 0.5)
        }
    }
}
