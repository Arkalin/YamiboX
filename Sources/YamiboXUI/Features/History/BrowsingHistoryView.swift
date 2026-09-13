import SwiftUI
import UIKit
import YamiboXCore

/// Searchable reading timeline shared by Mine and the previous-reading shelf.
struct BrowsingHistoryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: BrowsingHistoryViewModel
    private let appModel: YamiboAppModel
    private let onClose: (() -> Void)?
    private let categorySelection: Binding<BrowsingHistoryFilter>?
    private let onOpenThread: ((URL, String?) -> Void)?

    init(
        dependencies: LibraryDependencies,
        appModel: YamiboAppModel,
        showsPreviousReading: Bool = false,
        onClose: (() -> Void)? = nil,
        categorySelection: Binding<BrowsingHistoryFilter>? = nil,
        onOpenThread: ((URL, String?) -> Void)? = nil
    ) {
        let model = BrowsingHistoryViewModel(dependencies: dependencies, showsPreviousReading: showsPreviousReading)
        if let categorySelection { model.selectedFilter = categorySelection.wrappedValue }
        _model = State(initialValue: model)
        self.appModel = appModel
        self.onClose = onClose
        self.categorySelection = categorySelection
        self.onOpenThread = onOpenThread
    }

    var body: some View {
        LibraryPageNavigation(
            ownsNavigation: categorySelection == nil,
            onClose: onClose
        ) {
            historyList
            .safeAreaInset(edge: .top, spacing: 0) {
                categoryPicker
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.background)
                    .overlay(alignment: .bottom) { Divider() }
            }
            .navigationTitle(pageTitle)
            .yamiboInlineNavigationTitleDisplayMode()
            .searchable(text: searchTextBinding, prompt: L10n.string("history.search.prompt"))
            .toolbar {
                if !model.showsPreviousReading {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.prepareClearAllConfirmation() }
                        } label: {
                            Label(L10n.string("history.clear_all"), systemImage: "trash")
                        }
                        .disabled(model.entries.isEmpty)
                    }
                }
            }
        }
        .destructiveConfirmationDialog(
            L10n.string("history.clear_all.title"),
            isPresented: Bindable(model).clearAllConfirmationPresented,
            actionTitle: L10n.string("history.clear_all"),
            message: model.clearAllMessage
        ) {
            Task { await model.clearAll() }
        }
        .favoriteQuickActionDialogs(
            addPromptPresented: Bindable(model).favoriteAddPromptPresented,
            removePrompt: Bindable(model).favoriteRemovePrompt,
            onConfirmAdd: { syncToRemote, remember in
                Task { await model.confirmFavoriteAdd(syncToRemote: syncToRemote, remember: remember) }
            },
            onConfirmRemoval: { favorite, removeRemote, remember in
                Task { await model.confirmFavoriteRemoval(favorite, removeRemote: removeRemote, remember: remember) }
            }
        )
        .sheet(item: Bindable(model).favoriteLocationPickerContext) { context in
            FavoriteLocationPickerSheet(
                context: context,
                onCancel: { model.favoriteLocationPickerContext = nil },
                onConfirm: { locations in
                    Task { await model.confirmFavoriteLocationSelection(locations) }
                }
            )
        }
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: model.errorMessage,
            details: model.errorDetails,
            isPresented: errorIsPresented
        ) {
            Button(L10n.string("common.ok")) {
                model.clearError()
            }
        }
        .task {
            await model.load()
        }
        .task {
            await model.observeHistoryChanges()
        }
        .task {
            await model.observeFavoriteChanges()
        }
        .task {
            await model.observeSettingsChanges()
        }
        .onChange(of: model.selectedCategory) {
            if let categorySelection, categorySelection.wrappedValue != model.selectedFilter {
                categorySelection.wrappedValue = model.selectedFilter
            }
            Task { await model.reload() }
        }
        .onChange(of: categorySelection?.wrappedValue, initial: true) { _, selected in
            if let selected, model.selectedFilter != selected {
                model.selectedFilter = selected
            }
        }
        .onChange(of: model.searchText) {
            model.scheduleReload()
        }
        .transientMessage(model.transientFeedback, bottomPadding: 24) {
            model.clearTransientMessage()
        }
    }

    private var pageTitle: String {
        L10n.string(model.showsPreviousReading ? "home.previous" : "forum.history")
    }

    private var historyList: some View {
        List {
            ForEach(daySections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        row(for: entry)
                            .libraryWorkRowInsets()
                    }
                } header: {
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .padding(.vertical, 8)
                        .accessibilityAddTraits(.isHeader)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.isLoading, model.entries.isEmpty {
                ProgressView()
            } else if model.hasLoaded, model.entries.isEmpty {
                ContentUnavailableView {
                    Label(
                        L10n.string(isFiltering ? "history.empty.search" : "history.empty"),
                        systemImage: isFiltering ? "magnifyingglass" : "clock"
                    )
                } actions: {
                    if isFiltering {
                        Button(L10n.string("history.filter.reset")) {
                            model.searchText = ""
                            model.selectedCategory = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func row(for entry: BrowsingHistoryEntry) -> some View {
        BrowsingHistoryRow(
            entry: entry,
            category: model.effectiveCategory(for: entry),
            coverURL: model.coverURLsByEntryID[entry.id],
            isFavorited: model.isFavorited(entry),
            canToggleFavorite: model.heartThreadID(for: entry) != nil,
            onOpen: {
                Task { await open(entry) }
            },
            onToggleFavorite: {
                Task { await model.toggleFavorite(entry) }
            },
            onToggleFavoriteLongPress: {
                Task { await model.presentFavoriteLocationPicker(entry) }
            }
        )
        .deleteSwipeAction {
            Task { await model.delete(entry) }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.clearError()
                }
            }
        )
    }

    @ViewBuilder
    private var categoryPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            categoryOptions.pickerStyle(.menu)
        } else {
            categoryOptions.pickerStyle(.segmented)
        }
    }

    private var categoryOptions: some View {
        Picker(L10n.string("history.filter.all"), selection: Bindable(model).selectedCategory) {
            Text(L10n.string("history.filter.all")).tag(BrowsingHistoryCategory?.none)
            if !model.showsPreviousReading {
                Text(L10n.string("history.filter.normal")).tag(BrowsingHistoryCategory?.some(.normal))
            }
            Text(L10n.string("history.filter.novel")).tag(BrowsingHistoryCategory?.some(.novel))
            Text(L10n.string("history.filter.manga")).tag(BrowsingHistoryCategory?.some(.manga))
        }
        .labelsHidden()
        .accessibilityIdentifier("history.category.picker")
    }

    private var searchTextBinding: Binding<String> {
        Bindable(model).searchText
    }

    private var isFiltering: Bool {
        model.selectedCategory != nil || !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func open(_ entry: BrowsingHistoryEntry) async {
        guard let target = await model.openTarget(for: entry) else { return }
        switch target {
        case let .novelReader(context):
            appModel.presentNovelReader(context)
        case let .mangaReader(context):
            appModel.requestMangaReader(context)
        case let .nativeThread(url, title):
            if let onOpenThread {
                onOpenThread(url, title)
            } else {
                appModel.openNativeForumThread(url: url, title: title)
            }
        }
    }

    // MARK: - Date sections

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let entries: [BrowsingHistoryEntry]
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var sections: [DaySection] = []
        var currentDay: Date?
        var currentEntries: [BrowsingHistoryEntry] = []

        func flush() {
            guard let day = currentDay, !currentEntries.isEmpty else { return }
            sections.append(
                DaySection(
                    id: Self.sectionIDFormatter.string(from: day),
                    title: Self.sectionTitle(for: day, calendar: calendar),
                    entries: currentEntries
                )
            )
        }

        for entry in model.entries {
            let day = calendar.startOfDay(for: entry.lastVisitTime)
            if day != currentDay {
                flush()
                currentDay = day
                currentEntries = []
            }
            currentEntries.append(entry)
        }
        flush()
        return sections
    }

    private static func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return L10n.string("history.section.today")
        }
        if calendar.isDateInYesterday(day) {
            return L10n.string("history.section.yesterday")
        }
        if let daysAgo = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: .now)).day,
           (2...6).contains(daysAgo) {
            return L10n.string("history.section.days_ago", String(daysAgo))
        }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return Self.sameYearFormatter.string(from: day)
        }
        return Self.otherYearFormatter.string(from: day)
    }

    private static let sectionIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct BrowsingHistoryCategoryLinks: View {
    let filters: [BrowsingHistoryFilter]
    var selectedFilter: BrowsingHistoryFilter? = nil
    var onSelect: ((BrowsingHistoryFilter) -> Void)? = nil

    var body: some View {
        ForEach(filters, id: \.self) { filter in
            categoryRow(filter)
                .accessibilityIdentifier("history.category.\(filter.rawValue)")
        }
    }

    @ViewBuilder
    private func categoryRow(_ filter: BrowsingHistoryFilter) -> some View {
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

private struct BrowsingHistoryRow: View {
    @Environment(\.appTheme) private var appTheme
    let entry: BrowsingHistoryEntry
    /// Effective category (board configuration applied) — drives the
    /// position-text format so the row reads like the reader it would
    /// actually open with.
    let category: BrowsingHistoryCategory
    let coverURL: URL?
    let isFavorited: Bool
    let canToggleFavorite: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleFavoriteLongPress: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onOpen) {
                LibraryWorkRowContent(
                    title: entry.title,
                    coverURL: coverURL,
                    categoryTitle: Text(L10n.string("history.filter.\(category.rawValue)")),
                    timestamp: Text(entry.lastVisitTime, format: .dateTime.hour().minute()),
                    detail: positionText,
                    usesForumPlaceholder: category == .normal
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("history.open.\(entry.id)")

            if canToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorited ? "star.fill" : "star")
                        .font(.body.weight(.medium))
                        .foregroundStyle(isFavorited ? appTheme.controlAccent : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in onToggleFavoriteLongPress() }
                )
                .accessibilityLabel(
                    isFavorited
                        ? L10n.string("history.favorite.remove")
                        : L10n.string("history.favorite.add")
                )
                .accessibilityIdentifier("history.favorite.\(entry.id)")
            }
        }
    }

    private var positionText: String? {
        // The effective category can differ from the identity the row was
        // recorded under (board configuration changed since), so each branch
        // falls back across the recorded field shapes instead of assuming
        // its own — e.g. a row recorded as a normal thread (page only) still
        // shows its page under a now-小说 board rather than nothing.
        switch category {
        case .normal:
            if let pageIndex = entry.pageIndex {
                if let pageCount = entry.pageCount, pageCount > 1 {
                    return L10n.string("history.progress.page_of_total", String(pageIndex), String(pageCount))
                }
                return L10n.string("history.progress.page", String(pageIndex))
            }
            guard let chapterTitle = entry.chapterTitle, chapterTitle != entry.title else { return nil }
            return L10n.string("history.progress.chapter", chapterTitle)
        case .novel:
            if let chapterTitle = entry.chapterTitle {
                return L10n.string("history.progress.chapter", chapterTitle)
            }
            guard let pageIndex = entry.pageIndex else { return nil }
            return L10n.string("history.progress.page", String(pageIndex))
        case .manga:
            let pageText = entry.pageIndex.map { L10n.string("history.progress.page", String($0 + 1)) }
            if let chapterTitle = entry.chapterTitle, chapterTitle != entry.title {
                if let pageText {
                    return L10n.string("history.progress.manga", chapterTitle, pageText)
                }
                return L10n.string("history.progress.chapter", chapterTitle)
            }
            return pageText
        }
    }
}
