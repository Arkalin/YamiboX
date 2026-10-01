import SwiftUI
import YamiboXCore

struct FavoriteMemberManagementSheet: View {
    let actions: FavoriteActionController
    let mode: FavoriteMemberManagement
    @State private var memberActions: FavoriteActionController?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if mode == .locations {
                    FavoriteLocationMembershipList(
                        categories: actions.document.categories,
                        collections: actions.document.collections,
                        membership: LocalFavoriteLocationMembershipSnapshot(items: actions.members),
                        onSetLocation: { location, included in
                            Task { await actions.setMemberLocation(location, included: included) }
                        }
                    )
                    .disabled(!actions.canAct)
                } else {
                    List(actions.members) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.resolvedDisplayTitle)
                                Text(item.target.threadID ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(L10n.string("common.move")) {
                                    manage(item, move: true)
                                }
                                Button(L10n.string("history.favorite.remove"), role: .destructive) {
                                    manage(item, move: false)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.string("common.more"))
                            .accessibilityIdentifier("favorite-member.\(item.id)")
                            .disabled(!actions.canAct || memberActions?.isWorking == true)
                        }
                    }
                    .overlay {
                        if actions.members.isEmpty {
                            ContentUnavailableView(L10n.string("favorites.work.empty"), systemImage: "star")
                        }
                    }
                }
            }
            .navigationTitle(mode == .locations ? L10n.string("common.move") : L10n.string("favorites.view_archived_favorites"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) { dismiss() }
                }
            }
        }
        .favoriteActionInterface(memberActions)
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: actions.errorMessage,
            details: actions.errorDetails,
            isPresented: Binding(
                get: { actions.errorMessage != nil },
                set: { if !$0 { actions.clearError() } }
            )
        ) {
            Button(L10n.string("common.ok")) { actions.clearError() }
        }
        .transientMessage(actions.transientFeedback) { actions.clearTransientMessage() }
    }

    private func manage(_ item: FavoriteItem, move: Bool) {
        let child = actions.actions(for: item)
        memberActions = child
        Task {
            if move { await child.presentLocationPicker() }
            else { await child.toggleFavorite() }
        }
    }
}

/// Shared with the favorites tab's selection move sheet. Partial membership
/// is displayed explicitly instead of replacing every member with a union.
struct FavoriteLocationMembershipList: View {
    let categories: [FavoriteCategory]
    let collections: [LocalFavoriteCollection]
    let membership: LocalFavoriteLocationMembershipSnapshot
    let onSetLocation: (FavoriteLocation, Bool) -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        List {
            Section {
                Text(L10n.string("favorites.location.selected_items", membership.itemCount))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(categories.manualOrderSorted) { category in
                Section(category.displayName) {
                    row(title: category.displayName, symbol: "square.grid.2x2", location: .category(category.id))
                    ForEach(collections.filter { $0.categoryID == category.id }.sorted {
                        $0.manualOrder == $1.manualOrder ? $0.id < $1.id : $0.manualOrder < $1.manualOrder
                    }) { collection in
                        row(
                            title: collection.name, symbol: "folder", tint: collection.color.swiftUIColor,
                            location: .collection(categoryID: category.id, collectionID: collection.id)
                        )
                        .padding(.leading, 16)
                    }
                }
            }
            Section {
                Text(L10n.string("favorites.location.keep_one_hint"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func row(title: String, symbol: String, tint: Color? = nil, location: FavoriteLocation) -> some View {
        let state = membership.state(location)
        let image = state == .none ? "circle" : state == .all ? "checkmark.circle.fill" : "minus.circle.fill"
        return Button {
            onSetLocation(location, state != .all)
        } label: {
            HStack {
                Label {
                    Text(title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint ?? appTheme.controlAccent)
                }
                Spacer()
                Image(systemName: image)
                    .foregroundStyle(state == .none ? Color.secondary : appTheme.controlAccent)
            }
        }
        .accessibilityValue(L10n.string(state == .all ? "favorites.work.location_all" : state == .some ? "favorites.work.location_some" : "favorites.work.location_none"))
    }
}

struct FavoriteWorkRemovalSheet: View {
    let prompt: FavoriteGroupRemovalPrompt
    let onConfirm: (Bool, Bool) -> Void
    let onCancel: () -> Void
    @State private var remember = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.membership.smartMangaTitle ?? "")
                        .font(.headline)
                    Text(L10n.string("favorites.work.remove_message", prompt.membership.items.count))
                }
                if prompt.asksRemote {
                    Section {
                        Toggle(L10n.string("favorites.quick.add_prompt.remember"), isOn: $remember)
                        Button(L10n.string("favorites.quick.remove_prompt.both"), role: .destructive) { onConfirm(true, remember) }
                            .accessibilityIdentifier("favorite-work-remove-sync")
                        Button(L10n.string("favorites.quick.remove_prompt.local_only"), role: .destructive) { onConfirm(false, remember) }
                            .accessibilityIdentifier("favorite-work-remove-local")
                    }
                } else {
                    Section {
                        Button(L10n.string(prompt.removeRemote ? "favorites.quick.remove_prompt.both" : "favorites.quick.remove_prompt.local_only"), role: .destructive) {
                            onConfirm(prompt.removeRemote, false)
                        }
                        .accessibilityIdentifier("favorite-work-remove-confirm")
                    }
                }
            }
            .navigationTitle(L10n.string("favorites.work.remove"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
