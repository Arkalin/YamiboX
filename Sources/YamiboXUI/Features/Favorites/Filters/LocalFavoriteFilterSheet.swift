import SwiftUI
import YamiboXCore

/// Filter sheet behind the toolbar filter button: multi-select source groups
/// (Android's forum filter) and tags in one place.
struct LocalFavoriteFilterSheet: View {
    @ObservedObject var organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.string("favorites.source_group")) {
                    if availableSourceFilters.isEmpty {
                        Text(L10n.string("favorites.filter.all"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableSourceFilters, id: \.self) { sourceFilter in
                        Button {
                            toggleSourceFilter(sourceFilter)
                        } label: {
                            HStack {
                                Text(sourceFilter.displayLabel)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(organizer.derived.sourceFilterEntryCounts[sourceFilter] ?? 0)")
                                    .foregroundStyle(.secondary)
                                if organizer.filter.selectedSourceFilters.contains(sourceFilter) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
                Section(L10n.string("favorites.filter.tags")) {
                    if organizer.tags.isEmpty {
                        Text(L10n.string("favorites.tags.empty"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(organizer.tags) { tag in
                        Button {
                            toggleTag(tag.id)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tag.color.swiftUIColor)
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if organizer.filter.selectedTagIDs.contains(tag.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("favorites.filter.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.clear")) {
                        organizer.filter.selectedSourceFilters = []
                        organizer.filter.selectedTagIDs = []
                    }
                    .disabled(!organizer.filter.hasActiveFilters)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var availableSourceFilters: [LocalFavoriteSourceFilter] {
        organizer.derived.sourceFilterEntryCounts.keys.sorted {
            $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
        }
    }

    private func toggleSourceFilter(_ sourceFilter: LocalFavoriteSourceFilter) {
        if organizer.filter.selectedSourceFilters.contains(sourceFilter) {
            organizer.filter.selectedSourceFilters.remove(sourceFilter)
        } else {
            organizer.filter.selectedSourceFilters.insert(sourceFilter)
        }
    }

    private func toggleTag(_ tagID: String) {
        if organizer.filter.selectedTagIDs.contains(tagID) {
            organizer.filter.selectedTagIDs.remove(tagID)
        } else {
            organizer.filter.selectedTagIDs.insert(tagID)
        }
    }
}
