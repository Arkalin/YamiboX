import SwiftUI
import YamiboXCore

/// One favorite card in the grid layouts: 3:4 cover, two-line title, source,
/// plain time lines, tag chips. No visible buttons — tap resumes reading,
/// long-press opens the context menu.
struct LocalFavoriteGridCard: View {
    let card: FavoriteCardProjection
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let actions: LocalFavoriteCardActions

    var body: some View {
        Button(action: handleTap) {
            VStack(alignment: .leading, spacing: 8) {
                LocalFavoriteGridCover(url: card.coverURL, title: card.resolvedTitle)
                Text(card.resolvedTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                Text(card.sourceGroupLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LocalFavoriteCardTimeLines(card: card)
                LocalFavoriteTagChipRow(tags: card.tags)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // A smart card is selectable like any other card — selecting it is
            // equivalent to selecting every favorite archived under it, expanded
            // transparently at bulk-operation time by
            // `FavoriteLibraryOrganizer.expandedSelectionFavoriteIDs`; the id
            // that lands in `selection.selectedFavoriteIDs` here is still just
            // its own representative id.
            .favoriteSelectionEmphasis(isSelectionMode: selection.isSelectionMode, isSelected: isSelected, cornerRadius: 8)
            // Layered after `favoriteSelectionEmphasis`, not before: that
            // modifier's `.opacity()` forces an offscreen compositing pass sized
            // to the card's own frame, which clips any overlay poking past the
            // card's edge — including this badge's outward corner offset.
            .overlay(alignment: .topTrailing) {
                if card.isModeOnMangaThread {
                    LocalFavoriteSmartCardBadge()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .contextMenu {
            if !selection.isSelectionMode {
                LocalFavoriteCardContextMenu(card: card, actions: actions)
            }
        }
    }

    private func handleTap() {
        if selection.isSelectionMode {
            // A smart card toggles into `selection.selectedFavoriteIDs`
            // just like any other card — bulk operations expand it to
            // every archived member at execution time (see the
            // selection-emphasis comment above), including
            // `deleteSelection` when `smartMangaBulkDeleteEnabled` is on;
            // when it's off, `deleteSelection` excludes it there
            // instead of here, so it still requires the dedicated
            // "查看归档收藏" archive page.
            selection.toggleFavoriteSelection(id: card.id)
        } else {
            actions.open(card, .resume)
        }
    }

    private var isSelected: Bool {
        selection.selectedFavoriteIDs.contains(card.id)
    }
}

/// Cover image sized to a 3:4 aspect ratio for grid cards.
struct LocalFavoriteGridCover: View {
    let url: URL?
    let title: String

    var body: some View {
        // Width-driven 3:4 box; the thumbnail fills and clips inside it.
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                LocalFavoriteCoverThumbnail(url: url, title: title)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: .infinity)
    }
}
