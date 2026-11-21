import SwiftUI
import YamiboXCore

struct LocalFavoriteSelectionMoveSheet: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FavoriteLocationMembershipList(
                categories: organizer.categories,
                collections: organizer.collections,
                membership: organizer.selectionLocationSnapshot,
                onSetLocation: { location, included in
                    Task { await organizer.setSelectionLocation(location, included: included) }
                }
            )
            .navigationTitle(L10n.string("common.move"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            selection.exitSelectionMode()
        }
    }
}
