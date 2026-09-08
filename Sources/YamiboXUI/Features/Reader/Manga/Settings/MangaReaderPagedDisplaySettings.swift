import SwiftUI
import YamiboXCore

#if os(iOS)

struct MangaReaderPagedDisplaySettings: View {
    @Binding var settings: MangaReaderSettings
    let palette: MangaReaderSettingsPalette
    let usesTwoPageSpread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.string("manga.settings.paged_display"), systemImage: "rectangle.on.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .accessibilityAddTraits(.isHeader)

            if !usesTwoPageSpread {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("manga.page_scale_mode"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                    ReaderSettingsSegmentedControl(palette: palette) {
                        ForEach(MangaPageScaleMode.allCases, id: \.self) { mode in
                            ReaderSettingsSegmentButton(
                                title: mode.title,
                                isSelected: settings.pageScaleMode == mode,
                                palette: palette
                            ) {
                                settings.pageScaleMode = mode
                            }
                            .accessibilityIdentifier("manga.settings.scale.\(mode.rawValue)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.string("manga.page_scale_mode"))
                }
            }

            MangaReaderEdgeFillPicker(selection: $settings.pageEdgeFillStyle, palette: palette)

            ReaderSettingsDivider(palette: palette)
            Toggle(isOn: $settings.ignoresTopSafeArea) {
                Text(L10n.string("manga.ignores_top_safe_area"))
                    .font(.body)
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(palette.selectedControlBackground)
            .frame(minHeight: 44)
            .accessibilityIdentifier("manga.settings.ignoresTopSafeArea")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manga.settings.pagedDisplay")
    }
}

private struct MangaReaderEdgeFillPicker: View {
    @Binding var selection: MangaPageEdgeFillStyle
    let palette: MangaReaderSettingsPalette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("manga.page_edge_fill"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.secondaryText)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                ForEach(MangaPageEdgeFillStyle.allCases, id: \.self) { style in
                    MangaReaderEdgeFillButton(
                        style: style,
                        isSelected: selection == style,
                        usesRowLayout: dynamicTypeSize.isAccessibilitySize,
                        palette: palette
                    ) {
                        selection = style
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("manga.page_edge_fill"))
    }
}

private struct MangaReaderEdgeFillButton: View {
    let style: MangaPageEdgeFillStyle
    let isSelected: Bool
    let usesRowLayout: Bool
    let palette: MangaReaderSettingsPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let layout = usesRowLayout
                ? AnyLayout(HStackLayout(spacing: 12))
                : AnyLayout(VStackLayout(spacing: 8))
            layout {
                swatch
                Text(style.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: usesRowLayout ? .infinity : nil, alignment: .leading)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("manga.settings.edgeFill.\(style.rawValue)")
    }

    private var swatch: some View {
        ZStack {
            Circle()
                .fill(style == .black ? Color.black : .white)
                .overlay {
                    if style == .system {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 32))
                            .foregroundStyle(.black)
                    }
                }
                .overlay { Circle().strokeBorder(palette.secondaryText.opacity(0.4), lineWidth: 1) }
                .padding(4)
            Circle()
                .strokeBorder(isSelected ? palette.selectedControlBackground : .clear, lineWidth: 2)
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.selectedControlText)
                .frame(width: 18, height: 18)
                .background(palette.selectedControlBackground, in: Circle())
                .opacity(isSelected ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

#endif
