import SwiftUI
import YamiboXCore

/// Tri-state per-item location membership (all / some / none of the selected
/// items carry a location).
enum LocalFavoriteLocationTriState: Equatable {
    case none
    case some
    case all
}

/// Category → collection tree with tri-state boxes for the selected items'
/// locations, mirroring the Android collection picker. Items can live in
/// multiple locations; toggling a partially-selected location includes it
/// everywhere, toggling a full one removes it (keeping each item's last
/// location intact).
struct LocalFavoriteSelectionMoveSheet: View {
    let organizer: FavoriteLibraryOrganizer
    @ObservedObject var selection: LocalFavoriteBrowseSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.string("favorites.location.selected_items", selection.selectedFavoriteCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(organizer.categories.manualOrderSorted) { category in
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
                    }
                }
                Section {
                    Text(L10n.string("favorites.location.keep_one_hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
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

    private func collections(in categoryID: String) -> [LocalFavoriteCollection] {
        organizer.collections
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
        let state = organizer.selectionLocationState(location)
        return Button {
            Task {
                await organizer.setSelectionLocation(location, included: state != .all)
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
                Image(systemName: stateImageName(state))
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
            }
        }
    }

    private func stateImageName(_ state: LocalFavoriteLocationTriState) -> String {
        switch state {
        case .none:
            "circle"
        case .some:
            "minus.circle.fill"
        case .all:
            "checkmark.circle.fill"
        }
    }
}
