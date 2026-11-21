import SwiftUI
import YamiboXCore

struct LocalFavoriteItemRow: View {
    let card: FavoriteCardProjection
    let showsCover: Bool
    let showsSmartCardBadge: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let actions: LocalFavoriteCardActions
    @Namespace private var bookNamespace
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Button(action: handleTap) {
            rowContent
        }
        .buttonStyle(BookOpeningButtonStyle())
        .modifier(LocalFavoriteKeyboardActivation(action: handleTap))
        .contextMenu {
            if !isSelectionMode {
                LocalFavoriteCardContextMenu(card: card, actions: actions, bookOpeningTransition: bookOpeningTransition)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                if card.isModeOnMangaThread {
                    Button {
                        actions.viewArchivedFavorites(card)
                    } label: {
                        Label(L10n.string("favorites.view_archived_favorites"), systemImage: "archivebox")
                    }
                    .tint(.orange)
                    if let deleteArchivedFavorites = actions.deleteArchivedFavorites {
                        Button(role: .destructive) {
                            deleteArchivedFavorites(card.item)
                        } label: {
                            Label(L10n.string("common.delete"), systemImage: "trash")
                        }
                    }
                } else {
                    Button(role: .destructive) {
                        actions.delete(card)
                    } label: {
                        Label(L10n.string("common.delete"), systemImage: "trash")
                    }
                }
                Button {
                    actions.editTags(card.item)
                } label: {
                    Label(L10n.string("favorites.tags_action"), systemImage: "tag")
                }
                .tint(appTheme.controlAccent)
            }
        }
    }

    private func handleTap() {
        if isSelectionMode {
            onToggleSelection()
        } else {
            actions.open(card, .preferred, bookOpeningTransition)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if showsCover {
                BookCoverThumbnail(source: card.coverSource, title: card.resolvedTitle)
                    .frame(width: 92, height: 128)
                    .matchedTransitionSource(id: BookOpeningTransition.sourceID, in: bookNamespace)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.resolvedTitle)
                    .font(.body)
                    .lineLimit(2)
                Text(card.sourceGroupLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LocalFavoriteCardTimeLines(card: card)
                LocalFavoriteTagChipRow(tags: card.tags)
            }
            .matchedTransitionSource(id: showsCover ? "book-metadata" : BookOpeningTransition.sourceID, in: bookNamespace)
            Spacer(minLength: 0)
        }
        .padding(10)
        .contentShape(Rectangle())
        .favoriteSelectionEmphasis(isSelectionMode: isSelectionMode, isSelected: isSelected, cornerRadius: 10)
        .overlay(alignment: .topTrailing) {
            if showsSmartCardBadge, card.isModeOnMangaThread {
                LocalFavoriteSmartCardBadge()
            }
        }
    }

    private var bookOpeningTransition: BookOpeningTransition {
        BookOpeningTransition(namespace: bookNamespace)
    }
}
