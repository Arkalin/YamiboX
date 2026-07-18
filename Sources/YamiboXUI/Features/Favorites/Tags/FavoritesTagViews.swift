import SwiftUI
import YamiboXCore

extension FavoriteTagSortOrder {
    /// User-facing label for the tag sort menu; presentation mapping lives
    /// with the views, not the model.
    var title: String {
        switch self {
        case .manual: L10n.string("favorites.tag_sort.manual")
        case .name: L10n.string("favorites.tag_sort.name")
        case .nameDescending: L10n.string("favorites.tag_sort.name_desc")
        case .updatedAt: L10n.string("favorites.tag_sort.updated_at")
        case .updatedAtDescending: L10n.string("favorites.tag_sort.updated_at_desc")
        case .associationCount: L10n.string("favorites.tag_sort.association_count")
        case .associationCountDescending: L10n.string("favorites.tag_sort.association_count_desc")
        }
    }
}

struct LocalFavoriteTagSelectionDraft: Identifiable {
    enum Mode: Equatable {
        case filter
        case favorite(String)
        case selection
    }

    let id = UUID()
    var mode: Mode
    var initialTagIDs: Set<String>

    static func filter(_ tagIDs: Set<String>) -> LocalFavoriteTagSelectionDraft {
        LocalFavoriteTagSelectionDraft(mode: .filter, initialTagIDs: tagIDs)
    }

    static func favorite(_ itemID: String, initialTagIDs: Set<String>) -> LocalFavoriteTagSelectionDraft {
        LocalFavoriteTagSelectionDraft(mode: .favorite(itemID), initialTagIDs: initialTagIDs)
    }

    static func selection(_ initialTagIDs: Set<String>) -> LocalFavoriteTagSelectionDraft {
        LocalFavoriteTagSelectionDraft(mode: .selection, initialTagIDs: initialTagIDs)
    }
}

/// Tag picker sheet used for filtering, editing one favorite's tags, or bulk
/// tagging the current selection. Also hosts tag create/edit/delete/reorder,
/// bound directly to `FavoriteLibraryOrganizer` — no ViewModel/closures.
struct FavoriteTagPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let organizer: FavoriteLibraryOrganizer
    let draft: LocalFavoriteTagSelectionDraft

    @AppStorage(YamiboAppStorageKey.favoriteTagSortOrder) private var sortRawValue = FavoriteTagSortOrder.manual.rawValue
    @State private var selectedTagIDs: Set<String>
    @State private var searchText = ""
    @State private var editorDraft: FavoriteTagEditorDraft?
    @State private var pendingDeleteTag: FavoriteTag?
    @State private var isConfirming = false

    init(organizer: FavoriteLibraryOrganizer, draft: LocalFavoriteTagSelectionDraft) {
        self.organizer = organizer
        self.draft = draft
        _selectedTagIDs = State(initialValue: draft.initialTagIDs)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    tagSelectionHeader
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    if showsOverwriteWarning {
                        Text(L10n.string("favorites.tags_overwrite_warning"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    ForEach(visibleTags) { tag in
                        let isSelected = selectedTagIDs.contains(tag.id)

                        Button {
                            toggle(tag)
                        } label: {
                            FavoriteTagPickerRow(
                                tag: tag,
                                isSelected: isSelected,
                                includesReorderHandle: canReorderCurrentTags
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button {
                                editorDraft = FavoriteTagEditorDraft(tag: tag, defaultColor: nextDefaultColor)
                            } label: {
                                Label(L10n.string("common.edit"), systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                pendingDeleteTag = tag
                            } label: {
                                Label(L10n.string("common.delete"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveTags)
                }
                .overlay {
                    if organizer.tags.isEmpty {
                        ContentUnavailableView(L10n.string("favorites.tags.empty"), systemImage: "tag")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                tagSelectionFooter
            }
            .favoriteTagPickerSearch(text: $searchText)
            .navigationTitle(L10n.string("favorites.select_tags"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(visibleTagsAreFullySelected ? L10n.string("favorites.tags_deselect_all") : L10n.string("favorites.tags_select_all")) {
                        toggleVisibleTagsSelection()
                    }
                    .disabled(visibleTags.isEmpty)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorDraft = FavoriteTagEditorDraft(tag: nil, defaultColor: nextDefaultColor)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selectedTagIDs)
            .sheet(item: $editorDraft) { draft in
                FavoriteTagEditorView(draft: draft) { name, color in
                    if let tagID = draft.tag?.id {
                        await organizer.updateTag(id: tagID, name: name, color: color)
                        return true
                    }
                    guard let tag = await organizer.createTag(name: name, color: color) else {
                        return false
                    }
                    searchText = ""
                    selectedTagIDs.insert(tag.id)
                    return true
                } onCancel: {
                    editorDraft = nil
                }
            }
            .destructiveConfirmationAlert(
                item: $pendingDeleteTag,
                title: { _ in L10n.string("favorites.delete_tag") },
                actionTitle: { _ in L10n.string("common.delete") },
                message: { tag in L10n.string("favorites.delete_tag_message", tag.name) }
            ) { tag in
                Task {
                    await organizer.deleteTag(id: tag.id)
                    selectedTagIDs.remove(tag.id)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(canReorderCurrentTags ? .active : .inactive))
            #endif
        }
    }

    private var tagSelectionHeader: some View {
        tagSortMenu
    }

    private var tagSortMenu: some View {
        Menu {
            Picker(L10n.string("favorites.sort"), selection: $sortRawValue) {
                ForEach(FavoriteTagSortOrder.allCases) { sortOrder in
                    Text(sortOrder.title).tag(sortOrder.rawValue)
                }
            }
        } label: {
            VStack(spacing: 0) {
                Divider()

                HStack {
                    Text(L10n.string("favorites.sort"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(currentSortOrder.title)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)

                Divider()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tagSelectionFooter: some View {
        HStack {
            Button(L10n.string("common.cancel")) {
                dismiss()
            }
            .font(.headline)
            .foregroundStyle(.red)

            Spacer()

            Text(L10n.string("favorites.tags_selected_count", selectedTagIDs.count))
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Spacer()

            Button(L10n.string("common.ok")) {
                Task {
                    isConfirming = true
                    await confirm()
                    isConfirming = false
                }
            }
            .font(.headline)
            .disabled(isConfirming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }


    private var showsOverwriteWarning: Bool {
        draft.mode == .selection
    }

    private var nextDefaultColor: FavoriteTagColor {
        let colors = FavoriteTagColor.allCases
        guard !colors.isEmpty else { return .gray }
        return colors[organizer.tags.count % colors.count]
    }

    private var orderedTags: [FavoriteTag] {
        sortedFavoriteTags(organizer.tags, favorites: organizer.favoriteItems, sortOrder: currentSortOrder)
    }

    private var visibleTags: [FavoriteTag] {
        filteredFavoriteTags(orderedTags, searchText: searchText)
    }

    private var currentSortOrder: FavoriteTagSortOrder {
        FavoriteTagSortOrder(rawValue: sortRawValue) ?? .manual
    }

    private var canReorderCurrentTags: Bool {
        canReorderFavoriteTags(sortOrder: currentSortOrder, searchText: searchText)
    }

    private var visibleTagIDs: [String] {
        visibleTags.map(\.id)
    }

    private var visibleTagsAreFullySelected: Bool {
        let ids = Set(visibleTagIDs)
        return !ids.isEmpty && ids.isSubset(of: selectedTagIDs)
    }

    private func toggle(_ tag: FavoriteTag) {
        if selectedTagIDs.contains(tag.id) {
            selectedTagIDs.remove(tag.id)
        } else {
            selectedTagIDs.insert(tag.id)
        }
    }

    private func toggleVisibleTagsSelection() {
        let ids = Set(visibleTagIDs)
        if visibleTagsAreFullySelected {
            selectedTagIDs.subtract(ids)
        } else {
            selectedTagIDs.formUnion(ids)
        }
    }

    private func moveTags(fromOffsets: IndexSet, toOffset: Int) {
        guard canReorderCurrentTags else { return }
        var reorderedIDs = visibleTags.map(\.id)
        reorderedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        Task {
            await organizer.reorderTags(reorderedIDs)
        }
    }

    private func confirm() async {
        switch draft.mode {
        case .filter:
            organizer.filter.selectedTagIDs = selectedTagIDs
        case let .favorite(itemID):
            await organizer.updateTags(for: itemID, tagIDs: selectedTagIDs)
        case .selection:
            await organizer.updateTagsForSelection(selectedTagIDs)
        }
        dismiss()
    }
}

private struct FavoriteTagPickerRow: View {
    let tag: FavoriteTag
    let isSelected: Bool
    let includesReorderHandle: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tag.color.swiftUIColor)
                    .frame(width: isSelected ? 31 : 28, height: isSelected ? 31 : 28)

                Text(tagInitial)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(tag.color.iconTextColor)
            }
            .frame(width: 34, height: 34)
            .shadow(color: tag.color.swiftUIColor.opacity(isSelected ? 0.28 : 0.18), radius: 8, y: 4)

            Text(tag.name)
                .font(isSelected ? .body.weight(.semibold) : .body)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer()

            ZStack {
                if isSelected {
                    Circle()
                        .fill(tag.color.swiftUIColor)
                        .frame(width: 24, height: 24)

                    Image(systemName: "checkmark")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .stroke(.secondary.opacity(0.55), lineWidth: 2.25)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? tag.color.swiftUIColor.opacity(0.10) : .clear)
                .padding(.trailing, -selectionOutlineTrailingExtension)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? tag.color.swiftUIColor : .clear, lineWidth: 2)
                .padding(.trailing, -selectionOutlineTrailingExtension)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
    }

    private var tagInitial: String {
        let trimmedName = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.first.map(String.init) ?? "#"
    }

    private var selectionOutlineTrailingExtension: CGFloat {
        includesReorderHandle ? 52 : 0
    }
}

private extension View {
    @ViewBuilder
    func favoriteTagPickerSearch(text: Binding<String>) -> some View {
        self
            .searchable(
                text: text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.string("favorites.search_tags")
            )
    }
}

private struct FavoriteTagEditorView: View {
    let draft: FavoriteTagEditorDraft
    let onSave: (String, FavoriteTagColor) async -> Bool
    let onCancel: () -> Void

    @State private var name: String
    @State private var color: FavoriteTagColor
    @State private var isSaving = false

    init(
        draft: FavoriteTagEditorDraft,
        onSave: @escaping (String, FavoriteTagColor) async -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: draft.name)
        _color = State(initialValue: draft.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string("favorites.tag_name"), text: $name)
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                        ForEach(FavoriteTagColor.allCases, id: \.self) { tagColor in
                            Button {
                                color = tagColor
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(tagColor.swiftUIColor)
                                        .frame(width: 32, height: 32)
                                    if color == tagColor {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .disabled(isSaving)
            .navigationTitle(draft.tag == nil ? L10n.string("favorites.new_tag") : L10n.string("favorites.edit_tag"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        Task {
                            isSaving = true
                            let didSave = await onSave(name, color)
                            isSaving = false
                            if didSave {
                                onCancel()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
}
