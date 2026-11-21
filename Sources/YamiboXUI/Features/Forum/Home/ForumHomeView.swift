import SwiftUI
import YamiboXCore

struct ForumHomeView: View {
    @Environment(\.forumTheme) private var theme
    let model: ForumHomeViewModel
    let onBoardTap: (ForumBoardSummary) -> Void
    let onCarouselTap: (ForumHomeCarouselItem) -> Void

    var body: some View {
        Group {
            if model.isLoading && model.page == nil {
                ForumHomeSkeletonView()
            } else if let error = model.errorMessage, model.page == nil {
                LoadFailureView(message: error, details: model.errorDetails, retry: retry)
            } else if model.categories.isEmpty {
                ForumHomeEmptyView()
            } else {
                ForumHomeContentView(
                    categories: model.categories,
                    carouselItems: model.carouselItems,
                    expandedCategoryIDs: model.expandedCategoryIDs,
                    isRefreshing: model.isRefreshing,
                    toggleCategory: model.toggleCategory,
                    refresh: refresh,
                    onBoardTap: onBoardTap,
                    onCarouselTap: onCarouselTap
                )
            }
        }
        .forumPageBackground()
        .transientMessage(model.transientFeedback) {
            model.clearTransientMessage()
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
}

private struct ForumHomeSkeletonView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.mutedFill)
                    .aspectRatio(2.63, contentMode: .fit)

                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.mutedFill)
                            .frame(width: 96, height: 18)

                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(theme.surface)
                                .frame(height: 64)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollDisabled(true)
        .forumPageBackground()
        .opacity(isDimmed ? 0.6 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
            value: isDimmed
        )
        .onAppear {
            guard !reduceMotion else { return }
            isDimmed = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("common.loading"))
    }
}

private struct ForumHomeContentView: View {
    @Environment(\.forumTheme) private var theme
    let categories: [ForumCategory]
    let carouselItems: [ForumHomeCarouselItem]
    let expandedCategoryIDs: Set<String>
    let isRefreshing: Bool
    let toggleCategory: (String) -> Void
    let refresh: () async -> Void
    let onBoardTap: (ForumBoardSummary) -> Void
    let onCarouselTap: (ForumHomeCarouselItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                if !carouselItems.isEmpty {
                    ForumHomeCarouselView(items: carouselItems, onTap: onCarouselTap)
                }

                ForEach(categories) { category in
                    ForumCategorySectionView(
                        id: category.id,
                        title: category.title,
                        boards: category.boards,
                        isExpanded: expandedCategoryIDs.contains(category.id),
                        toggle: toggleCategory,
                        onBoardTap: onBoardTap
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .refreshableWithTopIndicator(isRefreshing: isRefreshing) {
            await refresh()
        }
        .forumPageBackground()
    }
}

private struct ForumHomeCarouselView: View {
    @Environment(\.forumTheme) private var theme
    let items: [ForumHomeCarouselItem]
    let onTap: (ForumHomeCarouselItem) -> Void

    @State private var selection = 0
    @State private var isUserInteracting = false
    @State private var lastUserInteraction = Date.distantPast
    @State private var lastAutoAdvance = Date.distantPast
    @State private var autoAdvanceSelection: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let autoAdvanceDwell: TimeInterval = 3

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                ForumHomePeekCarouselView(
                    items: items,
                    selection: $selection,
                    isUserInteracting: $isUserInteracting,
                    lastUserInteraction: $lastUserInteraction,
                    onTap: onTap
                )
            } else {
                fullWidthPager
            }
        }
        .onChange(of: items.count) { _, count in
            selection = min(selection, max(0, count - 1))
        }
        .onChange(of: selection) { _, newValue in
            if newValue != autoAdvanceSelection {
                lastUserInteraction = .now
            }
            autoAdvanceSelection = nil
        }
        .task(id: "\(items.map(\.id))-\(reduceMotion)") {
            guard items.count > 1, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard !isUserInteracting else { continue }
                let now = Date.now
                guard now.timeIntervalSince(lastUserInteraction) >= Self.autoAdvanceDwell,
                      now.timeIntervalSince(lastAutoAdvance) >= Self.autoAdvanceDwell else {
                    continue
                }
                lastAutoAdvance = now
                let next = (selection + 1) % items.count
                autoAdvanceSelection = next
                withAnimation(.easeInOut(duration: 0.25)) {
                    selection = next
                }
            }
        }
    }

    private var fullWidthPager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ForumCarouselImageButton(item: item, onTap: onTap)
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(
            id: Binding(get: { selection }, set: { if let index = $0 { selection = index } }),
            anchor: .center
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(2.63, contentMode: .fit)
        .onScrollPhaseChange { oldPhase, newPhase in
            let wasInteracting = oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating
            let isInteracting = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
            isUserInteracting = isInteracting
            if wasInteracting || isInteracting { lastUserInteraction = .now }
        }
        .onDisappear { isUserInteracting = false }
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { index in
                        Circle()
                            .fill(.white.opacity(index == selection ? 1 : 0.45))
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(6)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(.bottom, 6)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
    }
}

enum ForumHomeCarouselLoop {
    static func loopCount(itemCount: Int) -> Int {
        itemCount > 1 ? itemCount * 3 : itemCount
    }

    static func isCloneIndex(_ index: Int, itemCount: Int) -> Bool {
        itemCount > 1 && (index < itemCount || index >= 2 * itemCount)
    }

    static func middleLoopIndex(for selection: Int, itemCount: Int) -> Int {
        guard itemCount > 1 else { return 0 }
        return itemCount + min(max(selection, 0), itemCount - 1)
    }

    static func recenteredIndex(from current: Int, itemCount: Int) -> Int? {
        guard itemCount > 1 else { return nil }
        guard current >= 0, current < loopCount(itemCount: itemCount) else {
            return middleLoopIndex(for: 0, itemCount: itemCount)
        }
        guard isCloneIndex(current, itemCount: itemCount) else { return nil }
        return middleLoopIndex(for: current % itemCount, itemCount: itemCount)
    }

    static func hopTarget(from current: Int, to selection: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        guard current % itemCount != selection else { return nil }
        var delta = (selection - current % itemCount + itemCount) % itemCount
        if delta > itemCount / 2 {
            delta -= itemCount
        }
        let target = current + delta
        return min(max(target, 0), loopCount(itemCount: itemCount) - 1)
    }
}

struct ForumHomeCarouselPeekLayout: Equatable {
    static let maxCardWidth: CGFloat = 560
    static let minSideInset: CGFloat = 44
    static let cardSpacing: CGFloat = 12

    let cardWidth: CGFloat
    let sideInset: CGFloat

    init(containerWidth: CGFloat?) {
        guard let containerWidth, containerWidth > 0 else {
            cardWidth = Self.maxCardWidth
            sideInset = Self.minSideInset
            return
        }
        let width = min(Self.maxCardWidth, max(0, containerWidth - 2 * Self.minSideInset))
        cardWidth = width
        sideInset = max(Self.minSideInset, (containerWidth - width) / 2)
    }
}

private struct ForumHomePeekCarouselView: View {
    @Environment(\.forumTheme) private var theme
    let items: [ForumHomeCarouselItem]
    @Binding var selection: Int
    @Binding var isUserInteracting: Bool
    @Binding var lastUserInteraction: Date
    let onTap: (ForumHomeCarouselItem) -> Void

    @State private var containerWidth: CGFloat?
    @State private var indicatorWidth: CGFloat = 0
    @State private var scrolledLoopIndex: Int?

    private var layout: ForumHomeCarouselPeekLayout {
        ForumHomeCarouselPeekLayout(containerWidth: containerWidth)
    }

    private var loopCount: Int {
        ForumHomeCarouselLoop.loopCount(itemCount: items.count)
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: ForumHomeCarouselPeekLayout.cardSpacing) {
                    ForEach(0..<loopCount, id: \.self) { index in
                        ForumCarouselImageButton(item: items[index % items.count], onTap: onTap)
                            .frame(width: layout.cardWidth)
                            .accessibilityHidden(isCloneIndex(index))
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $scrolledLoopIndex, anchor: .center)
            .scrollIndicators(.hidden)
            .safeAreaPadding(.horizontal, layout.sideInset)
            .onScrollPhaseChange { _, newPhase in
                let isUserDriven = newPhase == .tracking
                    || newPhase == .interacting
                    || newPhase == .decelerating
                isUserInteracting = isUserDriven
                if isUserDriven {
                    lastUserInteraction = .now
                }
                if newPhase == .idle {
                    recenterIntoMiddleCopy()
                }
            }

            if items.count > 1 {
                pageIndicator
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        .onAppear {
            scrolledLoopIndex = middleLoopIndex(for: selection)
        }
        .onChange(of: scrolledLoopIndex) { _, newValue in
            guard let newValue, !items.isEmpty else { return }
            let canonical = newValue % items.count
            if selection != canonical {
                selection = canonical
            }
        }
        .onChange(of: selection) { _, newValue in
            scrollToSelection(newValue)
        }
        .onDisappear {
            isUserInteracting = false
        }
    }

    private func isCloneIndex(_ index: Int) -> Bool {
        ForumHomeCarouselLoop.isCloneIndex(index, itemCount: items.count)
    }

    private func middleLoopIndex(for selection: Int) -> Int {
        ForumHomeCarouselLoop.middleLoopIndex(for: selection, itemCount: items.count)
    }

    private func recenterIntoMiddleCopy() {
        guard let current = scrolledLoopIndex,
              let recentered = ForumHomeCarouselLoop.recenteredIndex(from: current, itemCount: items.count)
        else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrolledLoopIndex = recentered
        }
    }

    private func scrollToSelection(_ newSelection: Int) {
        guard !items.isEmpty else { return }
        guard let current = scrolledLoopIndex, current < loopCount else {
            scrolledLoopIndex = middleLoopIndex(for: newSelection)
            return
        }
        guard let target = ForumHomeCarouselLoop.hopTarget(
            from: current,
            to: newSelection,
            itemCount: items.count
        ) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            scrolledLoopIndex = target
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == selection ? theme.accentText : theme.divider.opacity(0.45))
                    .frame(width: index == selection ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            indicatorWidth = width
        }
        .onTapGesture { location in
            guard !items.isEmpty, indicatorWidth > 0 else { return }
            let slotWidth = indicatorWidth / CGFloat(items.count)
            let tappedIndex = min(max(Int(location.x / slotWidth), 0), items.count - 1)
            withAnimation(.easeInOut(duration: 0.25)) {
                selection = tappedIndex
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ForumCarouselImageButton: View {
    @Environment(\.forumTheme) private var theme
    let item: ForumHomeCarouselItem
    let onTap: (ForumHomeCarouselItem) -> Void

    var body: some View {
        Button {
            onTap(item)
        } label: {
            YamiboRemoteImage(source: YamiboImageSource(url: item.imageURL)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Rectangle().fill(theme.surface)
                    ProgressView()
                }
            } failure: {
                ZStack {
                    Rectangle().fill(theme.surface)
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(2.63, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!item.isThreadTarget)
    }
}

private struct ForumCategorySectionView: View {
    @Environment(\.forumTheme) private var theme
    let id: String
    let title: String
    let boards: [ForumBoardSummary]
    let isExpanded: Bool
    let toggle: (String) -> Void
    let onBoardTap: (ForumBoardSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    toggle(id)
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(theme.accentText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(L10n.string(isExpanded ? "common.collapse" : "common.expand"))

            if isExpanded {
                ForumCategoryBoardListView(
                    boards: boards,
                    onBoardTap: onBoardTap
                )
                .transition(.opacity)
            }
        }
        .clipped()
    }
}

private struct ForumCategoryBoardListView: View {
    @Environment(\.forumTheme) private var theme
    let boards: [ForumBoardSummary]
    let onBoardTap: (ForumBoardSummary) -> Void

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(boards) { board in
                ForumBoardRowView(
                    fid: board.fid,
                    name: board.name,
                    detail: board.detail,
                    todayCount: board.todayCount,
                    iconURL: board.iconURL,
                    onTap: {
                        onBoardTap(board)
                    }
                )
            }
        }
    }
}

private struct ForumBoardRowView: View {
    @Environment(\.forumTheme) private var theme
    let fid: String
    let name: String
    let detail: String?
    let todayCount: Int?
    let iconURL: URL?
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ForumBoardIconView(iconURL: iconURL, name: name)

                VStack(alignment: .leading, spacing: 4) {
                    titleLayout {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if let todayCount {
                            Text(L10n.string("forum.home.today_count", todayCount))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(theme.dangerFill, in: Capsule())
                        }
                    }

                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(12)
            .forumCardBackground()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forum-board-row-\(fid)")
    }

    @ViewBuilder
    private func titleLayout(@ViewBuilder content: () -> some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                content()
            }
        }
    }
}

private struct ForumBoardIconView: View {
    @Environment(\.forumTheme) private var theme
    let iconURL: URL?
    let name: String

    var body: some View {
        YamiboRemoteImage(source: iconURL.map { YamiboImageSource(url: $0) }) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(theme.secondaryText)
        } failure: {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(width: 38, height: 38)
        .background(theme.mutedFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ForumHomeEmptyView: View {
    @Environment(\.forumTheme) private var theme
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("forum.home.empty"), systemImage: "rectangle.stack")
        } description: {
            Text(L10n.string("forum.home.empty_message"))
        }
    }
}
