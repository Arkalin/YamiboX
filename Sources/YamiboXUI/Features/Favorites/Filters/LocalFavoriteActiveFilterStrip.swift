import SwiftUI
import YamiboXCore

/// Horizontal chips showing the active source-group and tag filters, with
/// one-tap clearing. The caller (`LocalFavoriteBrowseChrome`) only includes
/// this view while a filter is active, so it renders unconditionally.
struct LocalFavoriteActiveFilterStrip: View {
    @ObservedObject var organizer: FavoriteLibraryOrganizer

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let selectedSourceFilters = organizer.filter.selectedSourceFilters
                    .sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
                ForEach(selectedSourceFilters, id: \.self) { sourceFilter in
                    LocalFavoriteFilterChip(
                        title: sourceFilter.displayLabel,
                        systemImage: "line.3.horizontal.decrease.circle",
                        onClear: { organizer.filter.selectedSourceFilters.remove(sourceFilter) }
                    )
                }
                let selectedTags = organizer.tags.filter { organizer.filter.selectedTagIDs.contains($0.id) }
                ForEach(selectedTags) { tag in
                    LocalFavoriteFilterChip(
                        title: tag.name,
                        systemImage: "tag",
                        tint: tag.color.swiftUIColor,
                        onClear: { organizer.filter.selectedTagIDs.remove(tag.id) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

private struct LocalFavoriteFilterChip: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            Label {
                HStack(spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                    Image(systemName: "xmark.circle.fill")
                }
            } icon: {
                Image(systemName: systemImage)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
            .expandedHitTarget(width: 0)
        }
        .buttonStyle(.plain)
    }
}
