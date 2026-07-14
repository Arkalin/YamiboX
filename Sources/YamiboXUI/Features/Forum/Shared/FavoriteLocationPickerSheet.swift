import SwiftUI
import YamiboXCore

/// Presentation state for the star button's long-press "choose favorite
/// location" sheet — mirrors Android's collection picker dialog.
/// `initialSelection` is the target's current locations, pre-filling the
/// checklist exactly like Android's dialog (empty when not yet favorited).
struct FavoriteLocationPickerContext: Identifiable {
    let id = UUID()
    var document: FavoriteLibraryDocument
    var initialSelection: Set<FavoriteLocation>
    var isFavorited: Bool
    /// Carried alongside the snapshot so the presenting view doesn't need to
    /// separately expose its dependency just for this sheet — every view
    /// model already resolves its store when building this context.
    var localFavoriteLibraryStore: FavoriteLibraryStore
}

private struct PendingCollectionDraft: Identifiable {
    let id = UUID()
    let categoryID: String
    let draft: LocalFavoriteCollectionDraft
}

/// Multi-select category/collection checklist for filing a favorite —
/// created new or, for an already-favorited item, re-pinned to a different
/// set of locations. Confirming with every checkbox cleared on an
/// already-favorited item is a deliberate way to unfavorite (mirroring
/// Android); the caller routes that case through the normal remove flow
/// since `onConfirm` here only ever reports the raw selection.
///
/// Owns its own category/collection creation (via `localFavoriteLibraryStore`
/// directly) so "新建分类"/"新建合集" can be answered inline without a round
/// trip through the presenting view model — newly created locations are
/// selected automatically.
struct FavoriteLocationPickerSheet: View {
    let context: FavoriteLocationPickerContext
    let onCancel: () -> Void
    let onConfirm: (Set<FavoriteLocation>) -> Void

    @State private var document: FavoriteLibraryDocument
    @State private var selection: Set<FavoriteLocation>
    @State private var categoryNameDraft: LocalFavoriteCategoryNameDraft?
    @State private var pendingCollectionDraft: PendingCollectionDraft?
    @State private var errorMessage: String?

    init(
        context: FavoriteLocationPickerContext,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Set<FavoriteLocation>) -> Void
    ) {
        self.context = context
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _document = State(initialValue: context.document)
        _selection = State(initialValue: context.initialSelection)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(document.categories.manualOrderSorted) { category in
                    Section(category.displayName) {
                        locationRow(
                            title: category.displayName,
                            systemImage: "square.grid.2x2",
                            location: .category(category.id)
                        )
                        ForEach(collections(in: category.id)) { collection in
                            locationRow(
                                title: collection.name,
                                systemImage: "folder",
                                tint: collection.color.swiftUIColor,
                                location: .collection(categoryID: category.id, collectionID: collection.id)
                            )
                            .padding(.leading, 16)
                        }
                        Button {
                            pendingCollectionDraft = PendingCollectionDraft(
                                categoryID: category.id,
                                draft: LocalFavoriteCollectionDraft(mode: .create)
                            )
                        } label: {
                            Label(L10n.string("favorites.create_collection"), systemImage: "plus")
                        }
                    }
                }
                Section {
                    Button {
                        categoryNameDraft = LocalFavoriteCategoryNameDraft(mode: .create)
                    } label: {
                        Label(L10n.string("favorites.category.create"), systemImage: "plus")
                    }
                } footer: {
                    if context.isFavorited {
                        Text(L10n.string("favorites.location_picker.clear_all_hint"))
                    }
                }
            }
            .navigationTitle(L10n.string("favorites.location_picker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        onConfirm(selection)
                    }
                }
            }
        }
        .sheet(item: $categoryNameDraft) { draft in
            LocalFavoriteCategoryNameSheet(
                draft: draft,
                onCancel: { categoryNameDraft = nil },
                onSave: { name in
                    await createCategory(name: name)
                    categoryNameDraft = nil
                }
            )
        }
        .sheet(item: $pendingCollectionDraft) { pending in
            LocalFavoriteCollectionEditorSheet(
                draft: pending.draft,
                onCancel: { pendingCollectionDraft = nil },
                onSave: { name, color in
                    await createCollection(categoryID: pending.categoryID, name: name, color: color)
                    pendingCollectionDraft = nil
                }
            )
        }
        .alert(
            L10n.string("common.operation_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            )
        ) {
            Button(L10n.string("common.ok")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func collections(in categoryID: String) -> [LocalFavoriteCollection] {
        document.collections
            .filter { $0.categoryID == categoryID }
            .sorted { lhs, rhs in
                lhs.manualOrder == rhs.manualOrder ? lhs.id < rhs.id : lhs.manualOrder < rhs.manualOrder
            }
    }

    private func locationRow(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        location: FavoriteLocation
    ) -> some View {
        let isSelected = selection.contains(location)
        return Button {
            if isSelected {
                selection.remove(location)
            } else {
                selection.insert(location)
            }
        } label: {
            HStack {
                Label {
                    Text(title)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        }
    }

    private func createCategory(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let category = try await context.localFavoriteLibraryStore.update { document in
                document.createCategory(name: trimmed)
            }
            document.categories.append(category)
            selection.insert(.category(category.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createCollection(categoryID: String, name: String, color: FavoriteCollectionColor) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let collection = try await context.localFavoriteLibraryStore.update { document in
                document.createCollection(categoryID: categoryID, name: trimmed, color: color)
            }
            document.collections.append(collection)
            selection.insert(.collection(categoryID: categoryID, collectionID: collection.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
