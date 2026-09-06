import SwiftUI
import YamiboXCore

/// Cover with a text placeholder: when there is no cover URL or it fails to
/// load, the full title renders bold over a tinted background, its font size
/// stepped down by title length (Android CoverTextFallback parity).
///
/// Sizing goes through a `GeometryReader` rather than
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)`: inside a List row
/// whose tap target is a `Button` label, that greedy frame style can resolve
/// against the button's ideal-size measurement pass instead of the final
/// layout size, letting the cover balloon past its intended box (real images
/// bleeding outside their frame; the text fallback stretching to the row's
/// full width). `GeometryReader` always reports the size it was actually
/// proposed, so the explicit `.frame(width:height:)` callers apply is honored
/// exactly.
struct LocalFavoriteCoverThumbnail: View {
    let url: URL?
    let title: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let url {
                    YamiboRemoteImage(source: YamiboImageSource(url: url)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } placeholder: {
                        textFallback(in: proxy.size)
                    } failure: {
                        textFallback(in: proxy.size)
                    }
                } else {
                    textFallback(in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private func textFallback(in size: CGSize) -> some View {
        BookCoverTextFallback(title: title, boxWidth: size.width)
            .frame(width: size.width, height: size.height)
    }
}

/// Small sparkles badge overlaid on a smart-comic card's cover
/// (`FavoriteCardProjection.isModeOnMangaThread`), signaling this card's
/// title/content is Smart Comic Mode-managed — a locally-cleaned or shared
/// manga book name rather than the representative favorite's own raw post
/// title, whether or not it has actually merged with any sibling favorite
/// yet. Mirrors the styling technique — not the content — of
/// `LocalFavoritesOrganizationView`'s toolbar bell unread-count badge: a
/// small white glyph on a colored shape, offset to hang over the corner.
/// Purely a supplementary visual cue (the card's own accessibility label
/// already conveys its title), so it is hidden from the accessibility tree.
struct LocalFavoriteSmartCardBadge: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .padding(5)
            .background(appTheme.controlAccent, in: Circle())
            .offset(x: 5, y: -5)
            .accessibilityHidden(true)
    }
}

/// Width-filling 2x2 cover mosaic for the grid collection card: square tiles,
/// empty slots (fewer than 4 members) staying as collection-tinted squares.
/// Each occupied tile carries its own member's title, so a member with no
/// cover image renders its own text-fallback tile instead of being dropped.
struct LocalFavoriteCollectionMosaic: View {
    let color: Color
    let tiles: [LocalFavoriteCollectionPreviewTile]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { column in
                        tile(at: row * 2 + column)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        Group {
            if index < tiles.count {
                // Not layered under a background fill: BookCoverTextFallback's
                // own background is only ~12% opaque, so a collection-tinted
                // rectangle painted underneath it would bleed through and tint
                // every text-fallback tile with the collection's color.
                LocalFavoriteCoverThumbnail(url: tiles[index].coverURL, title: tiles[index].title)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.18))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity)
    }
}

/// Flexible 2x2 cover mosaic, sized entirely by whatever frame the caller
/// applies (list rows size it to match an item row's cover so collection and
/// favorite rows come out the same height; pickers can use a small square).
/// Each tile carries its own member's title, so a member with no cover image
/// renders its own text-fallback tile instead of being dropped.
struct LocalFavoriteCollectionCoverPreview: View {
    let color: Color
    let tiles: [LocalFavoriteCollectionPreviewTile]

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let columnWidth = (proxy.size.width - spacing) / 2
            let rowHeight = (proxy.size.height - spacing) / 2
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    tile(at: 0, width: columnWidth, height: rowHeight)
                    tile(at: 1, width: columnWidth, height: rowHeight)
                }
                HStack(spacing: spacing) {
                    tile(at: 2, width: columnWidth, height: rowHeight)
                    tile(at: 3, width: columnWidth, height: rowHeight)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(at index: Int, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if index < tiles.count {
                LocalFavoriteCoverThumbnail(url: tiles[index].coverURL, title: tiles[index].title)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(index == 0 ? 0.8 : 0.18))
            }
        }
        .frame(width: max(0, width), height: max(0, height))
    }
}
