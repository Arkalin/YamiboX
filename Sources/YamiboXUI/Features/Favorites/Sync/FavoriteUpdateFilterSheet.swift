import SwiftUI
import YamiboXCore

/// Per-forum and per-category toggles controlling which favorites are checked
/// for updates.
struct FavoriteUpdateFilterSheet: View {
    let fidFilters: [FavoriteUpdateFidFilter]
    let categoryFilters: [FavoriteUpdateCategoryFilter]
    let onSetFidEnabled: (String, Bool) async -> Void
    let onSetCategoryEnabled: (String, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(L10n.string("favorites.updates.filters.fids")) {
                if fidFilters.isEmpty {
                    Text(L10n.string("favorites.updates.filters.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fidFilters) { filter in
                        FavoriteUpdateFilterToggleRow(
                            title: filter.forumName,
                            subtitle: L10n.string("favorites.updates.filters.item_count", filter.itemCount),
                            isOn: filter.enabled,
                            onChange: { enabled in
                                await onSetFidEnabled(filter.fid, enabled)
                            }
                        )
                    }
                }
            }

            Section(L10n.string("favorites.updates.filters.categories")) {
                if categoryFilters.isEmpty {
                    Text(L10n.string("favorites.updates.filters.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categoryFilters) { filter in
                        FavoriteUpdateFilterToggleRow(
                            title: filter.categoryName,
                            subtitle: L10n.string("favorites.updates.filters.item_count", filter.itemCount),
                            isOn: filter.enabled,
                            onChange: { enabled in
                                await onSetCategoryEnabled(filter.categoryID, enabled)
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle(L10n.string("favorites.updates.filters"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("common.close")) {
                    dismiss()
                }
            }
        }
    }
}

private struct FavoriteUpdateFilterToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let onChange: (Bool) async -> Void

    var body: some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { enabled in
                Task { await onChange(enabled) }
            }
        )
    }
}
