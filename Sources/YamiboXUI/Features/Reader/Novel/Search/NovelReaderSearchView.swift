import Observation
import SwiftUI
import YamiboXCore

struct NovelReaderSearchPresentation: Identifiable {
    let id = UUID()
    let snapshot: NovelReaderSearchSnapshot
}

@MainActor
@Observable
final class NovelReaderSearchCoordinator {
    static let pageSize = 100

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            restartSearch()
        }
    }
    private(set) var matches: [NovelReaderSearchMatch] = []
    private(set) var isSearching = false
    private(set) var isSearchComplete = false
    private(set) var recentQueries: [String]
    private(set) var visibleLimit = pageSize

    @ObservationIgnored private let snapshot: NovelReaderSearchSnapshot
    @ObservationIgnored private let historyStore: NovelReaderSearchHistoryStore
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchRevision: UInt64 = 0

    init(
        snapshot: NovelReaderSearchSnapshot,
        defaults: UserDefaults = .standard,
        historyKey: String = YamiboAppStorageKey.readerSearchHistory
    ) {
        self.snapshot = snapshot
        historyStore = NovelReaderSearchHistoryStore(defaults: defaults, key: historyKey)
        recentQueries = historyStore.load()
    }

    deinit {
        searchTask?.cancel()
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var visibleMatches: ArraySlice<NovelReaderSearchMatch> {
        matches.prefix(visibleLimit)
    }

    var canLoadMore: Bool {
        matches.count > visibleLimit
    }

    func loadMore() {
        visibleLimit += Self.pageSize
    }

    func useRecentQuery(_ query: String) {
        self.query = query
    }

    func commitQueryToHistory() {
        let query = normalizedQuery
        guard !query.isEmpty else { return }
        recentQueries = historyStore.record(query)
    }

    func clearHistory() {
        historyStore.clear()
        recentQueries = []
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func restartSearch() {
        searchTask?.cancel()
        searchRevision &+= 1
        let revision = searchRevision
        let query = normalizedQuery
        matches = []
        visibleLimit = Self.pageSize
        isSearchComplete = query.isEmpty
        isSearching = !query.isEmpty
        guard !query.isEmpty else {
            searchTask = nil
            return
        }

        let snapshot = snapshot
        searchTask = Task { [weak self] in
            await NovelReaderSearchEngine.search(snapshot: snapshot, query: query) { [weak self] match in
                await self?.accept(match, revision: revision)
            }
            guard !Task.isCancelled else { return }
            self?.finish(revision: revision)
        }
    }

    private func accept(_ match: NovelReaderSearchMatch, revision: UInt64) {
        guard revision == searchRevision, !Task.isCancelled else { return }
        matches.append(match)
    }

    private func finish(revision: UInt64) {
        guard revision == searchRevision else { return }
        isSearching = false
        isSearchComplete = true
        searchTask = nil
    }
}

private struct NovelReaderSearchHistoryStore {
    private static let maximumCount = 10

    let defaults: UserDefaults
    let key: String

    func load() -> [String] {
        Array((defaults.stringArray(forKey: key) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniquedForReaderSearch()
            .prefix(Self.maximumCount))
    }

    func record(_ query: String) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return load() }
        let history = Array(([normalized] + load())
            .uniquedForReaderSearch()
            .prefix(Self.maximumCount))
        defaults.set(history, forKey: key)
        return history
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

private extension Array where Element == String {
    func uniquedForReaderSearch() -> [String] {
        reduce(into: []) { result, candidate in
            guard !result.contains(where: {
                $0.compare(candidate, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
            }) else { return }
            result.append(candidate)
        }
    }
}

struct NovelReaderSearchView: View {
    @State private var coordinator: NovelReaderSearchCoordinator
    let backgroundColor: Color
    let onSelect: (NovelReaderSearchMatch) -> Void
    let onDismiss: () -> Void

    init(
        snapshot: NovelReaderSearchSnapshot,
        backgroundColor: Color,
        onSelect: @escaping (NovelReaderSearchMatch) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _coordinator = State(initialValue: NovelReaderSearchCoordinator(snapshot: snapshot))
        self.backgroundColor = backgroundColor
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            NovelReaderSearchHeader()
            Divider()
            NovelReaderSearchContent(
                coordinator: coordinator,
                onSelect: select
            )
        }
        .background(backgroundColor.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NovelReaderSearchBottomBar(
                query: Binding(
                    get: { coordinator.query },
                    set: { coordinator.query = $0 }
                ),
                onSubmit: coordinator.commitQueryToHistory,
                onDismiss: onDismiss
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .onDisappear {
            coordinator.cancel()
        }
    }

    private func select(_ match: NovelReaderSearchMatch) {
        coordinator.commitQueryToHistory()
        onSelect(match)
    }
}

private struct NovelReaderSearchHeader: View {
    var body: some View {
        Text(L10n.string("reader.search.title"))
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 16)
    }
}

private struct NovelReaderSearchContent: View {
    let coordinator: NovelReaderSearchCoordinator
    let onSelect: (NovelReaderSearchMatch) -> Void

    var body: some View {
        if coordinator.normalizedQuery.isEmpty {
            NovelReaderRecentSearchesView(
                queries: coordinator.recentQueries,
                onSelect: coordinator.useRecentQuery,
                onClear: coordinator.clearHistory
            )
        } else {
            NovelReaderSearchResultsView(
                matches: coordinator.visibleMatches,
                totalCount: coordinator.matches.count,
                isSearching: coordinator.isSearching,
                isSearchComplete: coordinator.isSearchComplete,
                canLoadMore: coordinator.canLoadMore,
                onSelect: onSelect,
                onLoadMore: coordinator.loadMore
            )
        }
    }
}

private struct NovelReaderRecentSearchesView: View {
    let queries: [String]
    let onSelect: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text(L10n.string("reader.search.recent"))
                        .font(.headline)
                    Spacer()
                    Button(L10n.string("common.clear"), action: onClear)
                        .disabled(queries.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                if queries.isEmpty {
                    ContentUnavailableView(
                        L10n.string("reader.search.no_recent"),
                        systemImage: "clock"
                    )
                    .padding(.top, 44)
                } else {
                    ForEach(queries, id: \.self) { query in
                        Button {
                            onSelect(query)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                Text(query)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
    }
}

private struct NovelReaderSearchResultsView: View {
    let matches: ArraySlice<NovelReaderSearchMatch>
    let totalCount: Int
    let isSearching: Bool
    let isSearchComplete: Bool
    let canLoadMore: Bool
    let onSelect: (NovelReaderSearchMatch) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if matches.isEmpty {
                    searchEmptyState
                } else {
                    ForEach(matches) { match in
                        NovelReaderSearchResultRow(match: match) {
                            onSelect(match)
                        }
                        Divider().padding(.leading, 20)
                    }
                    NovelReaderSearchResultsFooter(
                        totalCount: totalCount,
                        isSearching: isSearching,
                        canLoadMore: canLoadMore,
                        onLoadMore: onLoadMore
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var searchEmptyState: some View {
        if isSearching {
            ProgressView(L10n.string("reader.search.searching"))
                .padding(.top, 72)
        } else if isSearchComplete {
            ContentUnavailableView(
                L10n.string("reader.search.no_results"),
                systemImage: "magnifyingglass"
            )
            .padding(.top, 44)
        }
    }
}

private struct NovelReaderSearchResultRow: View {
    let match: NovelReaderSearchMatch
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(match.chapterTitle ?? L10n.string("reader.current_web_page"))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    Text(match.positionLabel)
                        .font(.headline.weight(.regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                (Text(match.excerptPrefix)
                    + Text(match.matchedText).bold()
                    + Text(match.excerptSuffix))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(match.chapterTitle ?? L10n.string("reader.current_web_page"))，\(match.positionLabel)，\(match.excerptPrefix)\(match.matchedText)\(match.excerptSuffix)"
        )
    }
}

private struct NovelReaderSearchResultsFooter: View {
    let totalCount: Int
    let isSearching: Bool
    let canLoadMore: Bool
    let onLoadMore: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if canLoadMore {
                Button(L10n.string("reader.search.load_more"), action: onLoadMore)
                    .font(.headline)
            }
            HStack(spacing: 8) {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                Text(L10n.string("reader.search.match_count", totalCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct NovelReaderSearchBottomBar: View {
    @Binding var query: String
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ReaderGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.headline)
                    TextField(
                        L10n.string("reader.search.placeholder"),
                        text: $query
                    )
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("common.clear"))
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .readerChromePanel(cornerRadius: 26, tint: readerChromePanelTint(for: colorScheme))

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .buttonBorderShape(.circle)
                .readerChromeButtonStyle(tint: readerChromeButtonTint(for: colorScheme))
                .accessibilityLabel(L10n.string("common.close"))
            }
        }
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}
