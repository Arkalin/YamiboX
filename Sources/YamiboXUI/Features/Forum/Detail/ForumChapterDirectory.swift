import SwiftUI
import YamiboXCore

enum ChapterDirectoryLayout: String, CaseIterable, Sendable {
    case list
    case grid

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .list
    }
}

struct ChapterDirectoryItem: Identifiable, Equatable {
    let id: String
    let number: String
    let numberAccessibilityLabel: String
    let title: String
    var progressText: String?
    var isCurrentRead = false
    var isFocused = false

    static func novel(_ chapter: ForumNovelChapterSummary, indexInPage: Int) -> Self {
        let floor = chapter.floorText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(
            id: chapter.id,
            number: floor.isEmpty ? String(indexInPage + 1) : floor,
            numberAccessibilityLabel: floor.isEmpty ? L10n.string("forum.detail.page_item", indexInPage + 1) : floor,
            title: chapter.title,
            progressText: chapter.progressText,
            isCurrentRead: chapter.isCurrentRead
        )
    }

    static func manga(
        _ chapter: MangaChapter,
        bookName: String,
        focusedID: String?,
        currentReadID: String?,
        progressText: String?
    ) -> Self {
        let number = MangaChapterDisplayFormatter.displayNumber(for: chapter)
        let isCurrentRead = chapter.tid == currentReadID
        let isFocused = chapter.tid == focusedID
        return Self(
            id: chapter.tid,
            number: number,
            numberAccessibilityLabel: number,
            title: MangaChapterDisplayFormatter.readerHeaderTitle(rawTitle: chapter.rawTitle, cleanBookName: bookName),
            progressText: isCurrentRead ? progressText : nil,
            isCurrentRead: isCurrentRead,
            isFocused: isFocused
        )
    }

    var subtitle: String? {
        if isFocused && !isCurrentRead {
            return L10n.string("forum.thread_route.current_chapter_hint")
        }
        return progressText
    }

    var informationText: String {
        [
            isCurrentRead ? L10n.string("forum.detail.current_read") : nil,
            progressText
        ].compactMap { $0 }.joined(separator: ", ")
    }

    var accessibilityValue: String {
        [
            isCurrentRead ? L10n.string("forum.detail.current_read") : nil,
            isFocused ? L10n.string("forum.thread_route.current_chapter_hint") : nil,
            progressText
        ].compactMap { $0 }.joined(separator: ", ")
    }

    func outlineWidth(for layout: ChapterDirectoryLayout) -> CGFloat {
        // Reading fill and bookmark take precedence when both states coincide.
        guard !isCurrentRead else { return 0 }
        return isFocused ? 2 : (layout == .grid ? 0.5 : 0)
    }
}

struct ChapterDirectorySection: Identifiable, Equatable {
    let id: String
    var title: String?
    var isExpanded = true
    var isLoaded = true
    var isLoading = false
    var errorMessage: String?
    var errorDetails: LoadFailureDetails?
    var items: [ChapterDirectoryItem]
}

@MainActor
final class ChapterDirectoryScrollAnchor {
    var visibleIDs: Set<String>
    var pendingID: String?

    init(visibleIDs: Set<String> = []) {
        self.visibleIDs = visibleIDs
    }

    func prepareLayoutChange(orderedIDs: [String]) {
        pendingID = orderedIDs.first { visibleIDs.contains($0) }
    }

    func takePendingID(availableIDs: [String]) -> String? {
        defer { pendingID = nil }
        guard let pendingID, availableIDs.contains(pendingID) else { return nil }
        return pendingID
    }

    static func topAnchor(toolbarHeight: CGFloat, viewportHeight: CGFloat, itemHeight: CGFloat) -> UnitPoint {
        // ScrollViewReader's top anchor does not reserve pinned section-header
        // space. Offset the target below that header instead of hiding it.
        UnitPoint(x: 0.5, y: min(1, max(0, toolbarHeight / max(1, viewportHeight - itemHeight))))
    }
}

struct ForumChapterDirectory<Prelude: View>: View {
    @Environment(\.forumTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var itemHeight: CGFloat = 48
    @Binding var layout: ChapterDirectoryLayout
    // Visibility is bookkeeping, not rendered state. A reference avoids
    // invalidating the entire lazy directory for each item crossing the toolbar.
    @State private var scrollAnchor = ChapterDirectoryScrollAnchor()
    @State private var lastFocusedID: String?
    @State private var scrollRequest: ChapterDirectoryScrollRequest?
    @State private var toolbarHeight: CGFloat = 60
    @State private var viewportHeight: CGFloat = 400

    let sections: [ChapterDirectorySection]
    let countText: String
    var isLoading = false
    var errorMessage: String?
    var errorDetails: LoadFailureDetails?
    var initialFocusID: String?
    let refresh: () async -> Void
    var onSectionToggle: (String) -> Void = { _ in }
    var onSectionRetry: (String) -> Void = { _ in }
    let onChapterTap: (String) -> Void
    @ViewBuilder let prelude: () -> Prelude

    var body: some View {
        let orderedIDs = sections.filter(\.isExpanded).flatMap { $0.items.map(\.id) }
        let renderedLayout = layout
        let renderedFocusID = initialFocusID
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    prelude()
                    Section {
                        if sections.isEmpty {
                            if isLoading {
                                ForumContentLoadingView()
                            } else if let errorMessage {
                                ForumContentErrorView(message: errorMessage, details: errorDetails) {
                                    Task { await refresh() }
                                }
                                .padding(16)
                            } else {
                                ForumChapterDirectoryEmptyView()
                            }
                        } else {
                            ForEach(sections) { section in
                                ForumChapterDirectorySectionView(
                                    section: section,
                                    layout: layout,
                                    toolbarHeight: toolbarHeight,
                                    viewportHeight: viewportHeight,
                                    onVisibilityChange: { id, isVisible in
                                        if isVisible {
                                            scrollAnchor.visibleIDs.insert(id)
                                        } else {
                                            scrollAnchor.visibleIDs.remove(id)
                                        }
                                    },
                                    onToggle: { onSectionToggle(section.id) },
                                    onRetry: { onSectionRetry(section.id) },
                                    onChapterTap: onChapterTap
                                )
                            }
                        }
                    } header: {
                        ForumChapterDirectoryToolbar(
                            countText: countText,
                            layout: Binding(
                                get: { layout },
                                set: { newLayout in
                                    guard layout != newLayout else { return }
                                    scrollAnchor.prepareLayoutChange(orderedIDs: orderedIDs)
                                    layout = newLayout
                                }
                            )
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
                    }
                }
                .padding(.bottom, 16)
                .onGeometryChange(for: ChapterDirectoryRenderMeasurement.self) { geometry in
                    ChapterDirectoryRenderMeasurement(
                        size: geometry.size,
                        layout: renderedLayout,
                        itemIDs: orderedIDs,
                        focusID: renderedFocusID
                    )
                } action: { measurement in
                    if let target = scrollAnchor.takePendingID(availableIDs: measurement.itemIDs) {
                        scrollRequest = ChapterDirectoryScrollRequest(
                            id: target,
                            layout: measurement.layout,
                            anchor: ChapterDirectoryScrollAnchor.topAnchor(
                                toolbarHeight: toolbarHeight,
                                viewportHeight: viewportHeight,
                                itemHeight: itemHeight
                            )
                        )
                    } else if let initialFocusID,
                              initialFocusID != lastFocusedID,
                              measurement.itemIDs.contains(initialFocusID) {
                        lastFocusedID = initialFocusID
                        scrollRequest = ChapterDirectoryScrollRequest(id: initialFocusID, layout: measurement.layout, anchor: .center)
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                viewportHeight = height
            }
            .refreshable { await refresh() }
            .task(id: scrollRequest) {
                guard let scrollRequest, !Task.isCancelled else { return }
                // Scroll after the geometry transaction has completed. Scrolling
                // from its action recursively changes the geometry being measured.
                proxy.scrollTo(scrollRequest.id, anchor: scrollRequest.anchor)
            }
            .accessibilityIdentifier("forum.detail.directory")
        }
        .background(theme.surface)
        .tint(theme.accentText)
    }
}

private struct ChapterDirectoryRenderMeasurement: Equatable {
    let size: CGSize
    let layout: ChapterDirectoryLayout
    let itemIDs: [String]
    let focusID: String?
}

private struct ChapterDirectoryScrollRequest: Equatable {
    let id: String
    let layout: ChapterDirectoryLayout
    let anchor: UnitPoint
}

struct ForumChapterDirectoryToolbar: View {
    @Environment(\.forumTheme) private var theme
    let countText: String
    @Binding var layout: ChapterDirectoryLayout

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("manga.chapter_list"))
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(L10n.string("forum.detail.layout"), selection: $layout) {
                Image(systemName: "list.bullet")
                    .accessibilityLabel(L10n.string("forum.detail.layout_list"))
                    .tag(ChapterDirectoryLayout.list)
                Image(systemName: "square.grid.2x2")
                    .accessibilityLabel(L10n.string("forum.detail.layout_grid"))
                    .tag(ChapterDirectoryLayout.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 104, height: 44)
            .accessibilityIdentifier("forum.detail.layout")
            .help(L10n.string("forum.detail.layout"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 0.5)
        }
    }
}

private struct ForumChapterDirectorySectionView: View {
    @Environment(\.forumTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 56
    let section: ChapterDirectorySection
    let layout: ChapterDirectoryLayout
    let toolbarHeight: CGFloat
    let viewportHeight: CGFloat
    let onVisibilityChange: (String, Bool) -> Void
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onChapterTap: (String) -> Void

    var body: some View {
        let visibleTop = toolbarHeight
        let visibleBottom = viewportHeight
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title {
                Button(action: onToggle) {
                    HStack {
                        Text(title).font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(section.isExpanded ? 0 : -90))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(theme.mutedFill)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(L10n.string(section.isExpanded ? "forum.detail.expanded" : "forum.detail.collapsed"))
            }

            if section.isExpanded {
                if section.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                } else if let errorMessage = section.errorMessage {
                    ForumContentErrorView(message: errorMessage, details: section.errorDetails, retry: onRetry)
                        .padding(16)
                } else if section.isLoaded && section.items.isEmpty {
                    ForumChapterDirectoryEmptyView()
                } else {
                    LazyVGrid(
                        columns: layout == .grid
                            ? [GridItem(.adaptive(minimum: minimumColumnWidth), spacing: 8)]
                            : [GridItem(.flexible())],
                        spacing: layout == .grid ? 8 : 0
                    ) {
                        ForEach(section.items) { item in
                            ForumChapterDirectoryItemView(item: item, layout: layout) {
                                onChapterTap(item.id)
                            }
                            .id(item.id)
                            .onGeometryChange(for: Bool.self) { geometry in
                                let frame = geometry.frame(in: .scrollView(axis: .vertical))
                                // A pinned toolbar occludes content but does not
                                // reduce SwiftUI's scroll-target visible rectangle.
                                return frame.maxY > visibleTop + 1 && frame.minY < visibleBottom
                            } action: { isVisible in
                                onVisibilityChange(item.id, isVisible)
                            }
                            .onDisappear { onVisibilityChange(item.id, false) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, layout == .grid ? 12 : 0)
                }
            }
        }
    }
}

struct ForumChapterDirectoryItemView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .caption) private var numberWidth: CGFloat = 44
    @State private var showsTitle = false
    let item: ChapterDirectoryItem
    let layout: ChapterDirectoryLayout
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if layout == .grid {
                    Text(item.number)
                        .font(.body.weight(item.isCurrentRead ? .semibold : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: minimumHeight)
                } else {
                    HStack(spacing: 12) {
                        Text(item.number)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: numberWidth)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline.weight(item.isCurrentRead ? .semibold : .regular))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(item.isCurrentRead ? .white.opacity(0.85) : theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: item.isCurrentRead ? "bookmark.fill" : "chevron.right")
                            .font(.caption)
                            .frame(width: 16)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .frame(minHeight: minimumHeight)
                }
            }
            .foregroundStyle(item.isCurrentRead ? .white : theme.primaryText)
            .background(item.isCurrentRead ? theme.accent : (layout == .grid ? theme.mutedFill : theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: layout == .grid ? 8 : 0))
            .overlay {
                let outlineWidth = item.outlineWidth(for: layout)
                if outlineWidth > 0 {
                    RoundedRectangle(cornerRadius: layout == .grid ? 8 : 0)
                        .strokeBorder(
                            item.isFocused ? theme.accentText : theme.border,
                            lineWidth: outlineWidth
                        )
                }
            }
            .overlay(alignment: .topTrailing) {
                if layout == .grid && item.isCurrentRead {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if layout == .list && !item.isCurrentRead {
                    Rectangle().fill(theme.divider).frame(height: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.numberAccessibilityLabel), \(item.title)")
        .accessibilityValue(item.accessibilityValue)
        .accessibilityIdentifier("forum.detail.chapter.\(item.id)")
        .contextMenu {
            Button {
                showsTitle = true
            } label: {
                Label(L10n.string("forum.detail.chapter_title"), systemImage: "text.alignleft")
            }
        }
        .sheet(isPresented: $showsTitle) {
            ForumDetailInformationSheet(title: item.title, onCopyText: nil) {
                Text(item.numberAccessibilityLabel)
                    .foregroundStyle(theme.secondaryText)
                if !item.informationText.isEmpty {
                    Text(item.informationText)
                }
                ForumDetailReadButton(hasProgress: false) {
                    showsTitle = false
                    action()
                }
            }
            .environment(\.forumTheme, theme)
            .presentationDetents([.medium, .large])
        }
    }
}

private struct ForumChapterDirectoryEmptyView: View {
    var body: some View {
        ContentUnavailableView(L10n.string("forum.detail.empty_chapters"), systemImage: "list.bullet")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }
}
