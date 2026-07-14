import SwiftUI
import YamiboXCore

struct LocalFavoriteCategoryNameDraft: Identifiable {
    enum Mode {
        case create
        case rename(String)
    }

    let id = UUID()
    var mode: Mode
    var initialName: String = ""
}

/// Name entry sheet for creating or renaming a category.
struct LocalFavoriteCategoryNameSheet: View {
    let draft: LocalFavoriteCategoryNameDraft
    let onCancel: () -> Void
    let onSave: (String) async -> Void

    var body: some View {
        FavoriteNameEditorSheet(
            title: title,
            fieldLabel: L10n.string("favorites.category.name"),
            initialName: draft.initialName,
            onCancel: onCancel,
            onSave: onSave
        )
    }

    private var title: String {
        switch draft.mode {
        case .create:
            L10n.string("favorites.category.create")
        case .rename:
            L10n.string("favorites.category.rename")
        }
    }
}
