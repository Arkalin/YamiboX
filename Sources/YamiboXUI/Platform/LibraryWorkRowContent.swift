import SwiftUI

struct LibraryWorkRowContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var appTheme

    let title: String
    let coverURL: URL?
    let categoryTitle: Text
    let timestamp: Text
    let detail: String?
    var usesForumPlaceholder = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
                .frame(width: 64, height: 88)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        categoryLabel
                        timeLabel
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        categoryLabel
                        timeLabel
                    }
                }
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(minHeight: 88, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var cover: some View {
        if usesForumPlaceholder, coverURL == nil {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        } else {
            LocalFavoriteCoverThumbnail(url: coverURL, title: title)
        }
    }

    private var categoryLabel: some View {
        categoryTitle
            .font(.caption.weight(.medium))
            .foregroundStyle(appTheme.controlAccent)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var timeLabel: some View {
        timestamp
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    func libraryWorkRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 16))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
    }
}
