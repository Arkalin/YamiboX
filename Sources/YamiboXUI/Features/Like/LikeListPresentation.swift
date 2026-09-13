import SwiftUI
import YamiboXCore

enum LikeWorkFilter: CaseIterable, Hashable {
    case all, novel, manga

    var title: LocalizedStringResource {
        switch self {
        case .all: L10n.resource("likes.filter.all")
        case .novel: L10n.resource("likes.filter.novel")
        case .manga: L10n.resource("likes.filter.manga")
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .all: L10n.resource("likes.empty_state")
        case .novel: L10n.resource("likes.empty_novels")
        case .manga: L10n.resource("likes.empty_manga")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "heart"
        case .novel: "book.closed"
        case .manga: "photo.on.rectangle"
        }
    }

    func navigationTitle(usesSidebar: Bool, selectedCount: Int?) -> String {
        if let selectedCount {
            return L10n.string("likes.selected_count", selectedCount)
        }
        return usesSidebar ? String(localized: title) : L10n.string("likes.section_title")
    }

    func applying(to works: [LikeWorkSummary], titles: [LikeWorkKey: String], searchText: String) -> [LikeWorkSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return works.filter { work in
            let matchesKind = self == .all || (self == .novel ? work.workKey.kind == .novel : work.workKey.kind == .manga)
            return matchesKind && (query.isEmpty || (titles[work.workKey] ?? work.workKey.id).localizedCaseInsensitiveContains(query))
        }
    }
}

enum LikeContentFilter: CaseIterable, Hashable {
    case all, text, image

    var title: LocalizedStringResource {
        switch self {
        case .all: L10n.resource("likes.filter.all")
        case .text: L10n.resource("likes.filter.text")
        case .image: L10n.resource("likes.filter.image")
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .all: L10n.resource("likes.empty_state")
        case .text: L10n.resource("likes.empty_text")
        case .image: L10n.resource("likes.empty_images")
        }
    }

    func applying(to items: [LikeItem], chapterTitles: [String: String], searchText: String) -> [LikeItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            let matchesKind = self == .all || (self == .text ? item.kind == .text : item.kind == .image)
            guard matchesKind else { return false }
            return query.isEmpty || [item.excerptText, item.chapterTitle ?? chapterTitles[item.id]]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }
}

struct LikeWorkSidebarCategories: View {
    var selectedFilter: LikeWorkFilter? = nil
    var onSelect: ((LikeWorkFilter) -> Void)? = nil

    var body: some View {
        Section(L10n.resource("likes.filter.work_type")) {
            ForEach(LikeWorkFilter.allCases, id: \.self) { filter in
                categoryRow(filter)
                    .accessibilityIdentifier("likes.category.\(filter)")
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ filter: LikeWorkFilter) -> some View {
        if let onSelect {
            Button {
                onSelect(filter)
            } label: {
                Label(filter.title, systemImage: filter.systemImage)
            }
            .tag(filter)
            .sidebarCategorySelection(isSelected: selectedFilter.map { $0 == filter })
        } else {
            NavigationLink(value: filter) {
                Label(filter.title, systemImage: filter.systemImage)
            }
        }
    }
}

struct LikeWorkFilterBar: View {
    @Binding var selection: LikeWorkFilter

    var body: some View {
        Picker(L10n.resource("likes.filter.work_type"), selection: $selection) {
            ForEach(LikeWorkFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("likes.category.picker")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background, ignoresSafeAreaEdges: [])
    }
}

struct LikeContentFilterBar: View {
    @Binding var selection: LikeContentFilter
    let usesMenu: Bool

    var body: some View {
        Group {
            if usesMenu {
                HStack {
                    Spacer(minLength: 0)
                    Menu {
                        Picker(L10n.resource("likes.filter.content_type"), selection: $selection) {
                            ForEach(LikeContentFilter.allCases, id: \.self) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    } label: {
                        Label(selection.title, systemImage: "line.3.horizontal.decrease")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.resource("likes.filter.content_type"))
                    .accessibilityValue(Text(selection.title))
                    .accessibilityIdentifier("likes.contentFilter")
                }
            } else {
                Picker(L10n.resource("likes.filter.content_type"), selection: $selection) {
                    ForEach(LikeContentFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 16)
        .background(.background, ignoresSafeAreaEdges: [])
    }
}

struct LikeItemMetadata: View {
    let chapterTitle: String?
    let createdAt: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            if let chapterTitle {
                Text(chapterTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("like.chapterTitle")
            } else if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            Text(LocalFavoriteRelativeDate.string(from: createdAt))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("like.createdAt")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LikeWorkRow: View {
    let title: String
    let coverURL: URL?
    let kind: LikeWorkKind
    let itemCount: Int
    let lastLikedAt: Date
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LibraryWorkRowContent(
                title: title,
                coverURL: coverURL,
                categoryTitle: Text(kind == .novel ? LikeWorkFilter.novel.title : LikeWorkFilter.manga.title),
                timestamp: Text(LocalFavoriteRelativeDate.string(from: lastLikedAt)),
                detail: L10n.string("likes.item_count_format", itemCount)
            )

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isSelecting ? 0 : 1)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .favoriteSelectionEmphasis(
            isSelectionMode: isSelecting,
            isSelected: isSelected,
            cornerRadius: 8
        )
    }
}
