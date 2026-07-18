import SwiftUI
import YamiboXCore

/// One favorite row in the list layouts: cover thumbnail, two-line title,
/// source, plain time lines, and tag chips. No visible buttons — tap resumes
/// reading, long-press opens the context menu, swipes carry delete and tags.
struct LocalFavoriteItemRow: View {
    let card: FavoriteCardProjection
    let showsCover: Bool
    /// Mirrors `settings.favorites.smartMangaBadgeEnabled` (the "显示智能漫画
    /// 标识" Settings switch) — badge only, never any other smart-card gate.
    let showsSmartCardBadge: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let actions: LocalFavoriteCardActions

    var body: some View {
        Button {
            if isSelectionMode {
                // A smart card is selectable just like any other card —
                // bulk operations expand it to every archived member at
                // execution time (`FavoriteLibraryOrganizer
                // .expandedSelectionFavoriteIDs`), including
                // `deleteSelection` when `smartMangaBulkDeleteEnabled` is on;
                // when it's off, `deleteSelection` excludes it there
                // instead of here, so it still requires the dedicated
                // "查看归档收藏" archive page.
                onToggleSelection()
            } else {
                actions.open(card, .resume)
            }
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isSelectionMode {
                LocalFavoriteCardContextMenu(card: card, actions: actions)
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
                .tint(.indigo)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if showsCover {
                // Android row cards use a 92dp-wide 0.72-ratio cover.
                LocalFavoriteCoverThumbnail(url: card.coverURL, title: card.resolvedTitle)
                    .frame(width: 92, height: 128)
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
            Spacer(minLength: 0)
        }
        // Matches `LocalFavoriteGridCard`'s own padding so the selection
        // border below clears the text by the same margin in every layout.
        .padding(10)
        .contentShape(Rectangle())
        // A smart card is selectable just like any other card — see the
        // tap-gate above.
        .favoriteSelectionEmphasis(isSelectionMode: isSelectionMode, isSelected: isSelected, cornerRadius: 10)
        // Layered after `favoriteSelectionEmphasis`, not before: see
        // `LocalFavoriteGridCard` — its `.opacity()` would otherwise clip
        // this badge's outward corner offset.
        .overlay(alignment: .topTrailing) {
            if showsSmartCardBadge, card.isModeOnMangaThread {
                LocalFavoriteSmartCardBadge()
            }
        }
    }
}
