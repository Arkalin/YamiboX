import SwiftUI
import YamiboXCore

/// One collection row in the list layouts, mixed into the same section as
/// the favorite item rows.
struct LocalFavoriteCollectionRow: View {
    let collection: LocalFavoriteCollection
    let itemCount: Int
    let categories: [FavoriteCategory]
    let showsCover: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let previewTiles: [LocalFavoriteCollectionPreviewTile]
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onDissolve: () -> Void
    let onMove: (CategoryMoveDirection) async -> Void
    let onMoveToCategory: (String) async -> Void

    var body: some View {
        Button {
            if isSelectionMode {
                onToggleSelection()
            } else {
                onOpen()
            }
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isSelectionMode {
                LocalFavoriteCollectionContextMenu(
                    collection: collection,
                    categories: categories,
                    onSelect: onToggleSelection,
                    onEdit: onEdit,
                    onDissolve: onDissolve,
                    onMove: onMove,
                    onMoveToCategory: onMoveToCategory
                )
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if showsCover {
                // Matches the item row's cover box so collection and
                // favorite rows come out the same height.
                LocalFavoriteCollectionCoverPreview(
                    color: collection.color.swiftUIColor,
                    tiles: previewTiles
                )
                .frame(width: 92, height: 128)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.name)
                    .font(.body)
                    .lineLimit(1)
                Text(L10n.string("favorites.collection_summary", itemCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        // Matches `LocalFavoriteGridCard`'s own padding so the selection
        // border below clears the text by the same margin in every layout.
        .padding(10)
        .contentShape(Rectangle())
        .favoriteSelectionEmphasis(isSelectionMode: isSelectionMode, isSelected: isSelected, cornerRadius: 10)
    }
}

/// One collection cell in the grid layouts: mixed into the same grid as item
/// cards (collections first), with the width-filling 2x2 mosaic on top and
/// the collection color as border tint (Android CollectionCardUi parity).
struct LocalFavoriteCollectionGridCard: View {
    let collection: LocalFavoriteCollection
    let itemCount: Int
    let categories: [FavoriteCategory]
    let isSelectionMode: Bool
    let isSelected: Bool
    let previewTiles: [LocalFavoriteCollectionPreviewTile]
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onDissolve: () -> Void
    let onMove: (CategoryMoveDirection) async -> Void
    let onMoveToCategory: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalFavoriteCollectionMosaic(
                color: collection.color.swiftUIColor,
                tiles: previewTiles
            )
            Text(collection.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(L10n.string("favorites.collection_summary", itemCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(collection.color.swiftUIColor.opacity(0.45), lineWidth: 1.5)
        }
        .favoriteSelectionEmphasis(isSelectionMode: isSelectionMode, isSelected: isSelected, cornerRadius: 8)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if isSelectionMode {
                onToggleSelection()
            } else {
                onOpen()
            }
        }
        .contextMenu {
            if !isSelectionMode {
                LocalFavoriteCollectionContextMenu(
                    collection: collection,
                    categories: categories,
                    onSelect: onToggleSelection,
                    onEdit: onEdit,
                    onDissolve: onDissolve,
                    onMove: onMove,
                    onMoveToCategory: onMoveToCategory
                )
            }
        }
    }
}

/// Shared context-menu content for collection rows and cards.
struct LocalFavoriteCollectionContextMenu: View {
    let collection: LocalFavoriteCollection
    let categories: [FavoriteCategory]
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDissolve: () -> Void
    let onMove: (CategoryMoveDirection) async -> Void
    let onMoveToCategory: (String) async -> Void

    var body: some View {
        Button(action: onEdit) {
            Label(L10n.string("common.edit"), systemImage: "pencil")
        }
        Button(action: onSelect) {
            Label(L10n.string("common.select"), systemImage: "checkmark.circle")
        }
        Button {
            Task { await onMove(.up) }
        } label: {
            Label(L10n.string("favorites.category.move_up"), systemImage: "arrow.up")
        }
        Button {
            Task { await onMove(.down) }
        } label: {
            Label(L10n.string("favorites.category.move_down"), systemImage: "arrow.down")
        }
        Menu {
            ForEach(categories.manualOrderSorted) { category in
                Button {
                    Task { await onMoveToCategory(category.id) }
                } label: {
                    if category.id == collection.categoryID {
                        Label(category.displayName, systemImage: "checkmark")
                    } else {
                        Text(category.displayName)
                    }
                }
                .disabled(category.id == collection.categoryID)
            }
        } label: {
            Label(L10n.string("favorites.category.select"), systemImage: "folder")
        }
        Divider()
        Button(role: .destructive, action: onDissolve) {
            Label(L10n.string("favorites.dissolve"), systemImage: "folder.badge.minus")
        }
    }
}
