import SwiftUI
import YamiboXCore

struct LocalFavoriteGridCard: View {
    let card: FavoriteCardProjection
    let showsSmartCardBadge: Bool
    @ObservedObject var selection: LocalFavoriteBrowseSession
    let actions: LocalFavoriteCardActions
    @Namespace private var bookNamespace

    var body: some View {
        Button(action: handleTap) {
            VStack(alignment: .leading, spacing: 8) {
                LocalFavoriteGridCover(source: card.coverSource, title: card.resolvedTitle)
                    .matchedTransitionSource(id: BookOpeningTransition.sourceID, in: bookNamespace)
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
            .favoriteSelectionEmphasis(isSelectionMode: selection.isSelectionMode, isSelected: isSelected, cornerRadius: 8)
            .overlay(alignment: .topTrailing) {
                if showsSmartCardBadge, card.isModeOnMangaThread {
                    LocalFavoriteSmartCardBadge()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(BookOpeningButtonStyle())
        .modifier(LocalFavoriteKeyboardActivation(action: handleTap))
        .contextMenu {
            if !selection.isSelectionMode {
                LocalFavoriteCardContextMenu(card: card, actions: actions, bookOpeningTransition: bookOpeningTransition)
            }
        }
    }

    private func handleTap() {
        if selection.isSelectionMode {
            selection.toggleFavoriteSelection(id: card.id)
        } else {
            actions.open(card, .preferred, bookOpeningTransition)
        }
    }

    private var isSelected: Bool {
        selection.selectedFavoriteIDs.contains(card.id)
    }

    private var bookOpeningTransition: BookOpeningTransition {
        BookOpeningTransition(namespace: bookNamespace)
    }
}

struct LocalFavoriteGridCover: View {
    let source: YamiboImageSource?
    let title: String

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                BookCoverThumbnail(source: source, title: title)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: .infinity)
    }
}
