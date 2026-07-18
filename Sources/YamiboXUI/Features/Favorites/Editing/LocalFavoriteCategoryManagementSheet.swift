import SwiftUI
import YamiboXCore

/// Category management sheet: select, rename, reorder, and delete categories.
struct LocalFavoriteCategoryManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeleteCategory: FavoriteCategory?

    let organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes

    var body: some View {
        NavigationStack {
            List {
                categoryRow(defaultCategory)

                ForEach(movableCategories) { category in
                    categoryRow(category)
                }
                .onMove(perform: moveCategories)
            }
            .navigationTitle(L10n.string("favorites.category.manage"))
            .destructiveConfirmationAlert(
                item: $pendingDeleteCategory,
                title: { _ in L10n.string("favorites.category.delete") },
                actionTitle: { _ in L10n.string("common.delete") },
                message: { category in
                    L10n.string(
                        "favorites.category.delete_message",
                        category.displayName,
                        organizer.derived.categoryEntryCounts[category.id] ?? 0
                    )
                }
            ) { category in
                Task {
                    await organizer.deleteCategory(id: category.id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: FavoriteCategory) -> some View {
        HStack(spacing: 12) {
            Button {
                organizer.selectedCategoryID = category.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.displayName)
                        if organizer.display.showsCategoryCounts {
                            Text(L10n.string("favorites.items_count", organizer.derived.categoryEntryCounts[category.id] ?? 0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if category.id == organizer.selectedCategoryID {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !category.isDefault {
                Menu {
                    Button {
                        organizer.selectedCategoryID = category.id
                    } label: {
                        Label(L10n.string("favorites.category.select"), systemImage: "checkmark.circle")
                    }
                    Button {
                        routes.sheet = .categoryName(LocalFavoriteCategoryNameDraft(
                            mode: .rename(category.id),
                            initialName: category.displayName
                        ))
                    } label: {
                        Label(L10n.string("favorites.category.rename"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDeleteCategory = category
                    } label: {
                        Label(L10n.string("favorites.category.delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.string("common.more"))
            }
        }
    }


    private var sortedCategories: [FavoriteCategory] {
        organizer.categories.manualOrderSorted
    }

    private var defaultCategory: FavoriteCategory {
        sortedCategories.first(where: \.isDefault) ?? .defaultCategory
    }

    private var movableCategories: [FavoriteCategory] {
        sortedCategories.filter { !$0.isDefault }
    }

    private func moveCategories(fromOffsets: IndexSet, toOffset: Int) {
        var reorderedIDs = movableCategories.map(\.id)
        reorderedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        Task {
            await organizer.reorderCategories(reorderedIDs)
        }
    }
}
