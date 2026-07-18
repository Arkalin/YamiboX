import SwiftUI

#if os(iOS)

/// Title + trailing switch row; replaces `MangaReaderSettingsToggleRow` and
/// `NovelReaderToggleRow`.
///
/// Layout uses Manga's explicit constants (stack spacing 12, spacer floor 8);
/// Novel relied on stack defaults, but because the spacer absorbs all slack
/// between the leading text and the trailing toggle, both variants rendered
/// identically for every existing row. Manga's former `statusText`/`isEnabled`
/// parameters had no callers anywhere in the repo, so they were dropped
/// rather than carried into the shared component.
struct ReaderSettingsToggleRow<Palette: ReaderSettingsPalette>: View {
    let title: String
    let palette: Palette
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title3)
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

#endif
