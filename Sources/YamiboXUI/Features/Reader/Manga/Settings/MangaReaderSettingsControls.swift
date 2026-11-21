import SwiftUI
import YamiboXCore

#if os(iOS)


struct MangaReaderBrightnessRow: View {
    @Binding var value: Double
    let palette: MangaReaderSettingsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(L10n.string("manga.brightness"))
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(palette.warmAccent)
                }
                .foregroundStyle(palette.primaryText)

                Spacer()

                Text("\(Int((value * 100).rounded()))%")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }

            HStack(spacing: 14) {
                ReaderSettingsStepperButton(
                    systemName: "minus",
                    palette: palette,
                    diameter: 42
                ) {
                    value = max(0.25, value - 0.05)
                }

                Slider(value: $value, in: 0.25 ... 1.5, step: 0.05)
                    .tint(palette.warmAccent)

                ReaderSettingsStepperButton(
                    systemName: "plus",
                    palette: palette,
                    diameter: 42
                ) {
                    value = min(1.5, value + 0.05)
                }
            }
        }
    }
}

extension ReaderSettingsReadingModeOption {
    init(_ settings: MangaReaderSettings) {
        self.init(isPaged: settings.readingMode == .paged)
    }
}

extension MangaPageEdgeFillStyle {
    func settingsPreviewColor(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .white:
            Color.white
        case .black:
            Color.black
        case .system:
            colorScheme == .dark ? Color.black : Color.white
        }
    }
}

extension MangaReaderSettings {
    var usesPagedMode: Bool {
        readingMode == .paged
    }

    mutating func selectMode(_ option: ReaderSettingsReadingModeOption) {
        readingMode = option == .paged ? .paged : .vertical
    }
}
#endif
