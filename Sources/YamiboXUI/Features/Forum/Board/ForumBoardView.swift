import SwiftUI
import YamiboXCore

struct ForumBoardView: View {
    let onSubBoardTap: (ForumBoardSummary) -> Void
    let onPinnedTap: (ForumPinnedItem) -> Void
    let onThreadTap: (ForumThreadSummary) -> Void
    let onAuthorTap: (String, String?) -> Void
    let onSearchTap: () -> Void
    let onPostThreadTap: () -> Void

    @State private var model: ForumBoardViewModel
    @State private var isReaderSettingsPresented = false

    init(
        model: ForumBoardViewModel,
        onSubBoardTap: @escaping (ForumBoardSummary) -> Void,
        onPinnedTap: @escaping (ForumPinnedItem) -> Void,
        onThreadTap: @escaping (ForumThreadSummary) -> Void,
        onAuthorTap: @escaping (String, String?) -> Void,
        onSearchTap: @escaping () -> Void,
        onPostThreadTap: @escaping () -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onSubBoardTap = onSubBoardTap
        self.onPinnedTap = onPinnedTap
        self.onThreadTap = onThreadTap
        self.onAuthorTap = onAuthorTap
        self.onSearchTap = onSearchTap
        self.onPostThreadTap = onPostThreadTap
    }

    var body: some View {
        ForumBoardBodyView(
            page: model.page,
            subBoards: model.subBoards,
            pinnedItems: model.pinnedItems,
            threads: model.threads,
            pageNavigation: model.pageNavigation,
            filters: model.filters,
            orders: model.orders,
            selectedFilterTitle: model.selectedFilterTitle,
            selectedOrderTitle: model.selectedOrderTitle,
            isLoading: model.isLoading,
            isRefreshing: model.isRefreshing,
            errorMessage: model.errorMessage,
            retry: retry,
            refresh: refresh,
            goToPage: goToPage,
            selectFilter: selectFilter,
            selectOrder: selectOrder,
            onSubBoardTap: onSubBoardTap,
            onPinnedTap: onPinnedTap,
            onThreadTap: onThreadTap,
            onAuthorTap: onAuthorTap
        )
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(L10n.string("forum.home.search_placeholder"))

                Menu {
                    Button(action: onPostThreadTap) {
                        Label(L10n.string("forum.board.post_thread"), systemImage: "square.and.pencil")
                    }
                    Button {
                        Task {
                            await model.addFavorite()
                        }
                    } label: {
                        Label(
                            model.isFavoriting ? L10n.string("forum.board.favoriting") : L10n.string("forum.board.favorite"),
                            systemImage: "star"
                        )
                    }
                    .disabled(model.isFavoriting)
                    Button {
                        isReaderSettingsPresented = true
                    } label: {
                        Label(L10n.string("forum.board.reader_settings"), systemImage: "book")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.string("common.more"))
            }
        }
        .sheet(isPresented: $isReaderSettingsPresented) {
            ForumBoardReaderSettingsSheet(model: model)
        }
        .alert(
            L10n.string("common.operation_failed"),
            isPresented: Binding(
                get: { model.favoriteMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.favoriteMessage = nil
                    }
                }
            )
        ) {
            Button(L10n.string("common.ok")) {
                model.favoriteMessage = nil
            }
        } message: {
            Text(model.favoriteMessage ?? "")
        }
        .transientMessage(model.transientMessage) {
            model.clearTransientMessage()
        }
        .task {
            await model.load()
        }
    }

    private func retry() {
        Task {
            await model.load()
        }
    }

    private func refresh() async {
        await model.refresh()
    }

    private func goToPage(_ page: Int) {
        Task {
            await model.goToPage(page)
        }
    }

    private var selectFilter: @Sendable (String?) -> Void {
        { [model] id in
            Task { await model.selectFilter(id: id) }
        }
    }

    private var selectOrder: @Sendable (String?) -> Void {
        { [model] id in
            Task { await model.selectOrder(id: id) }
        }
    }
}

private struct ForumBoardOptionItem: Identifiable, Equatable {
    let id: String
    let optionID: String?
    let title: String
    let isSelected: Bool
}

private struct ForumBoardBodyView: View {
    let page: ForumBoardPage?
    let subBoards: [ForumBoardSummary]
    let pinnedItems: [ForumPinnedItem]
    let threads: [ForumThreadSummary]
    let pageNavigation: ForumPageNavigation?
    let filters: [ForumFilterOption]
    let orders: [ForumOrderOption]
    let selectedFilterTitle: String
    let selectedOrderTitle: String
    let isLoading: Bool
    let isRefreshing: Bool
    let errorMessage: String?
    let retry: () -> Void
    let refresh: () async -> Void
    let goToPage: (Int) -> Void
    let selectFilter: @Sendable (String?) -> Void
    let selectOrder: @Sendable (String?) -> Void
    let onSubBoardTap: (ForumBoardSummary) -> Void
    let onPinnedTap: (ForumPinnedItem) -> Void
    let onThreadTap: (ForumThreadSummary) -> Void
    let onAuthorTap: (String, String?) -> Void

    var body: some View {
        if isLoading && page == nil {
            ForumContentLoadingView(layout: .fillsPage)
        } else if let errorMessage, page == nil {
            ForumBoardErrorView(message: errorMessage, retry: retry)
        } else if let page {
            ForumBoardContentView(
                board: page.board,
                subBoards: subBoards,
                pinnedItems: pinnedItems,
                threads: threads,
                pageNavigation: pageNavigation,
                showsFilter: !filters.isEmpty,
                showsOrder: !orders.isEmpty,
                selectedFilterTitle: selectedFilterTitle,
                selectedOrderTitle: selectedOrderTitle,
                isRefreshing: isRefreshing,
                refresh: refresh,
                goToPage: goToPage,
                filters: filters,
                orders: orders,
                selectFilter: selectFilter,
                selectOrder: selectOrder,
                onSubBoardTap: onSubBoardTap,
                onPinnedTap: onPinnedTap,
                onThreadTap: onThreadTap,
                onAuthorTap: onAuthorTap
            )
        } else {
            ForumBoardEmptyView(retry: retry)
        }
    }
}

private struct ForumBoardContentView: View {
    let board: ForumBoardSummary
    let subBoards: [ForumBoardSummary]
    let pinnedItems: [ForumPinnedItem]
    let threads: [ForumThreadSummary]
    let pageNavigation: ForumPageNavigation?
    let showsFilter: Bool
    let showsOrder: Bool
    let selectedFilterTitle: String
    let selectedOrderTitle: String
    let isRefreshing: Bool
    let refresh: () async -> Void
    let goToPage: (Int) -> Void
    let filters: [ForumFilterOption]
    let orders: [ForumOrderOption]
    let selectFilter: @Sendable (String?) -> Void
    let selectOrder: @Sendable (String?) -> Void
    let onSubBoardTap: (ForumBoardSummary) -> Void
    let onPinnedTap: (ForumPinnedItem) -> Void
    let onThreadTap: (ForumThreadSummary) -> Void
    let onAuthorTap: (String, String?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                headerOptionsView

                if !subBoards.isEmpty {
                    ForumSubBoardSectionView(boards: subBoards, onTap: onSubBoardTap)
                }

                if !pinnedItems.isEmpty {
                    ForumPinnedSectionView(items: pinnedItems, onTap: onPinnedTap)
                }

                if threads.isEmpty {
                    ForumBoardNoThreadsView()
                } else {
                    ForEach(threads) { thread in
                        ForumThreadSummaryRowView(
                            thread: thread,
                            onThreadTap: {
                                onThreadTap(thread)
                            },
                            onAuthorTap: onAuthorTap
                        )
                    }
                }

                if let pageNavigation {
                    ForumPageNavigationBar(
                        navigation: pageNavigation,
                        currentPage: pageNavigation.currentPage,
                        goToPage: goToPage
                    )
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .refreshable {
            await refresh()
        }
        .topRefreshIndicator(isVisible: isRefreshing)
        .forumPageBackground()
    }

    private var headerOptionsView: some View {
        ForumBoardStatsView(
            todayCount: board.todayCount,
            threadCount: board.threadCount,
            rank: board.rank,
            showsFilter: showsFilter,
            showsOrder: showsOrder,
            selectedFilterTitle: selectedFilterTitle,
            selectedOrderTitle: selectedOrderTitle,
            filterItems: filterItems,
            orderItems: orderItems,
            selectFilter: selectFilter,
            selectOrder: selectOrder
        )
    }

    private var filterItems: [ForumBoardOptionItem] {
        [ForumBoardOptionItem(
            id: "all",
            optionID: nil,
            title: L10n.string("forum.board.all"),
            isSelected: selectedFilterTitle == L10n.string("forum.board.all")
        )] + filters.map { option in
            ForumBoardOptionItem(
                id: option.id,
                optionID: option.id,
                title: option.title,
                isSelected: option.title == selectedFilterTitle
            )
        }
    }

    private var orderItems: [ForumBoardOptionItem] {
        [ForumBoardOptionItem(
            id: "all",
            optionID: nil,
            title: L10n.string("forum.board.all"),
            isSelected: selectedOrderTitle == L10n.string("forum.board.all")
        )] + orders.map { option in
            ForumBoardOptionItem(
                id: option.id,
                optionID: option.id,
                title: option.title,
                isSelected: option.title == selectedOrderTitle
            )
        }
    }
}

private struct ForumBoardStatsView: View {
    let todayCount: Int?
    let threadCount: Int?
    let rank: Int?
    let showsFilter: Bool
    let showsOrder: Bool
    let selectedFilterTitle: String
    let selectedOrderTitle: String
    let filterItems: [ForumBoardOptionItem]
    let orderItems: [ForumBoardOptionItem]
    let selectFilter: @Sendable (String?) -> Void
    let selectOrder: @Sendable (String?) -> Void

    var body: some View {
        ViewThatFits {
            HStack(spacing: 8) {
                statChips
                Spacer(minLength: 8)
                optionButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                statChips
                optionButtons
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [ForumColors.brownDeep, ForumColors.brownPrimary.opacity(0.85)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var statChips: some View {
        HStack(spacing: 8) {
            if let todayCount {
                ForumStatChipView(label: L10n.string("forum.board.today"), value: String(todayCount))
            }
            if let threadCount {
                ForumStatChipView(label: L10n.string("forum.board.threads"), value: String(threadCount))
            }
            if let rank {
                ForumStatChipView(label: L10n.string("forum.board.rank"), value: String(rank))
            }
        }
    }

    private var optionButtons: some View {
        HStack(spacing: 8) {
            if showsOrder {
                ForumBoardOptionMenuButton(
                    title: selectedOrderTitle,
                    systemImage: "arrow.up.arrow.down",
                    menuTitle: L10n.string("forum.board.order"),
                    items: orderItems,
                    select: selectOrder
                )
            }

            if showsFilter {
                ForumBoardOptionMenuButton(
                    title: selectedFilterTitle,
                    systemImage: "line.3.horizontal.decrease.circle",
                    menuTitle: L10n.string("forum.board.filter"),
                    items: filterItems,
                    select: selectFilter
                )
            }
        }
    }
}

private struct ForumBoardOptionMenuButton: View {
    let title: String
    let systemImage: String
    let menuTitle: String
    let items: [ForumBoardOptionItem]
    let select: @Sendable (String?) -> Void

    private var selection: Binding<String?> {
        Binding(
            get: { items.first(where: \.isSelected)?.optionID },
            set: select
        )
    }

    var body: some View {
        Menu {
            Picker(menuTitle, selection: selection) {
                ForEach(items) { item in
                    Text(item.title).tag(item.optionID)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(.white.opacity(0.18), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.26), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ForumStatChipView: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.white.opacity(0.78))
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(ForumColors.redAccent)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.white.opacity(0.14), in: Capsule())
    }
}

private struct ForumSubBoardSectionView: View {
    let boards: [ForumBoardSummary]
    let onTap: (ForumBoardSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("forum.board.sub_boards"))
                .font(.headline)
                .foregroundStyle(ForumColors.brownPrimary)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(boards) { board in
                        Button {
                            onTap(board)
                        } label: {
                            Label(board.name, systemImage: "folder")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .foregroundStyle(ForumColors.textDark)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .forumCardBackground()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ForumPinnedSectionView: View {
    let items: [ForumPinnedItem]
    let onTap: (ForumPinnedItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("forum.board.pinned"))
                .font(.headline)
                .foregroundStyle(ForumColors.brownPrimary)

            ForEach(items) { item in
                ForumPinnedRowView(
                    id: item.id,
                    title: item.title,
                    kind: item.kind,
                    onTap: {
                        onTap(item)
                    }
                )
            }
        }
    }
}

private struct ForumPinnedRowView: View {
    let id: String
    let title: String
    let kind: ForumPinnedItem.Kind
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(kind == .announcement ? L10n.string("forum.board.announcement") : L10n.string("forum.board.pinned_badge"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ForumColors.textDark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ForumColors.orangeAccent, in: Capsule())

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ForumColors.textDark)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(11)
            .forumCardBackground(fill: kind == .announcement ? ForumColors.announcementBackground : ForumColors.pinnedBackground)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forum-pinned-row-\(id)")
    }
}



private struct ForumBoardErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack {
            VStack(spacing: 12) {
                Text(L10n.string("common.load_failed"))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(ForumColors.textDark)

                Text(message)
                    .font(.caption)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ForumColors.brownPrimary.opacity(0.75))

                Button(action: retry) {
                    Text(L10n.string("common.retry"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(ForumColors.brownDeep, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: 360)
            .background(ForumColors.creamSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: ForumColors.brownDeep.opacity(0.14), radius: 12, x: 0, y: 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .forumPageBackground()
    }
}

private struct ForumBoardEmptyView: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("forum.board.empty"), systemImage: "list.bullet.rectangle")
        } description: {
            Text(L10n.string("forum.board.empty_message"))
        } actions: {
            Button(L10n.string("common.retry"), action: retry)
        }
    }
}

private struct ForumBoardNoThreadsView: View {
    var body: some View {
        ContentUnavailableView(
            L10n.string("forum.board.no_threads"),
            systemImage: "text.bubble",
            description: Text(L10n.string("forum.board.no_threads_message"))
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
