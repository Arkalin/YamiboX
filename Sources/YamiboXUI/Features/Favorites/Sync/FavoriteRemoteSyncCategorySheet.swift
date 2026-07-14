import SwiftUI
import YamiboXCore

/// Target-category picker shown before starting a remote favorite sync.
struct FavoriteRemoteSyncCategorySheet: View {
    let categories: [FavoriteCategory]
    let selectedCategoryID: String
    let onCancel: () -> Void
    let onStart: (String) async -> Void

    var body: some View {
        NavigationStack {
            List(categories) { category in
                Button {
                    Task { await onStart(category.id) }
                } label: {
                    HStack {
                        Label(category.displayName, systemImage: category.isDefault ? "tray" : "folder")
                        Spacer()
                        if category.id == selectedCategoryID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("favorites.sync.category.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
            }
        }
    }
}
