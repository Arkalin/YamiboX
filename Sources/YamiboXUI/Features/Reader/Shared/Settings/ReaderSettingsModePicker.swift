import SwiftUI
import YamiboXCore

#if os(iOS)

/// Reading-mode choice shared by both reader settings sheets.
///
/// The Manga and Novel pickers offered the same four options with the same
/// titles, icons, and mapping onto the core reading-mode/turn-style pair —
/// only each reader's settings type differed. This enum replaces
/// `MangaReaderSettingsModeOption` and the private
/// `NovelReaderReadingModeOption`; each reader keeps a thin
/// `init(_ settings:)` next to its own code.
enum ReaderSettingsReadingModeOption: CaseIterable, Hashable {
    case slide
    case pageCurl
    case quickFade
    case scroll

    init(isPaged: Bool, pagedTurnStyle: ReaderPagedTurnStyle) {
        guard isPaged else {
            self = .scroll
            return
        }
        switch pagedTurnStyle {
        case .slide: self = .slide
        case .pageCurl: self = .pageCurl
        case .quickFade: self = .quickFade
        }
    }

    var title: String {
        switch self {
        case .slide: L10n.string("reading_mode.slide")
        case .pageCurl: L10n.string("reading_mode.page_curl")
        case .quickFade: L10n.string("reading_mode.quick_fade")
        case .scroll: L10n.string("reading_mode.scroll")
        }
    }

    var systemImageName: String {
        switch self {
        case .slide: "arrow.left.to.line.square"
        case .pageCurl: "doc"
        case .quickFade: "bolt.square"
        case .scroll: "text.page"
        }
    }

    var readingMode: ReaderReadingMode {
        switch self {
        case .slide, .pageCurl, .quickFade: .paged
        case .scroll: .vertical
        }
    }

    /// nil for vertical scrolling, which has no paged turn style.
    var pagedTurnStyle: ReaderPagedTurnStyle? {
        switch self {
        case .slide: .slide
        case .pageCurl: .pageCurl
        case .quickFade: .quickFade
        case .scroll: nil
        }
    }
}

/// Two-column reading-mode grid; replaces `MangaReaderModePicker` and
/// `NovelReaderReadingModePicker` (identical layout, columns, and title key).
struct ReaderSettingsModePicker<Palette: ReaderSettingsPalette>: View {
    let selection: ReaderSettingsReadingModeOption
    let palette: Palette
    let onSelect: (ReaderSettingsReadingModeOption) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("reading_mode.title"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ReaderSettingsReadingModeOption.allCases, id: \.self) { option in
                    ReaderSettingsModeButton(
                        option: option,
                        isSelected: selection == option,
                        palette: palette
                    ) {
                        onSelect(option)
                    }
                }
            }
        }
    }
}

private struct ReaderSettingsModeButton<Palette: ReaderSettingsPalette>: View {
    let option: ReaderSettingsReadingModeOption
    let isSelected: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: option.systemImageName)
                    .font(.headline.weight(.semibold))
                    .frame(width: 24)

                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(isSelected ? palette.selectedControlText : palette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(
                isSelected ? palette.selectedControlBackground : palette.segmentedBackground,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        // Novel's original button declared this; it is invisible and equally
        // valid for Manga, so the shared button keeps it for both.
        .accessibilityLabel(option.title)
    }
}

#endif
