import SwiftUI
import YamiboXCore

struct ForumHomeView: View {
    let model: ForumHomeViewModel
    let onBoardTap: (ForumBoardSummary) -> Void
    let onCarouselTap: (ForumHomeCarouselItem) -> Void

    var body: some View {
        Group {
            if model.isLoading && model.page == nil {
                ForumHomeSkeletonView()
            } else if let error = model.errorMessage, model.page == nil {
                LoadFailureView(message: error, retry: retry)
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
        .transientMessage(model.transientMessage) {
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

/// Content-shaped placeholder for the first load: a banner block and two
/// board sections where the real page will appear, gently pulsing. Reads as
/// "the page is coming" rather than a context-free spinner.
private struct ForumHomeSkeletonView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ForumColors.mutedFill)
                    .aspectRatio(2.63, contentMode: .fit)

                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ForumColors.mutedFill)
                            .frame(width: 96, height: 18)

                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(ForumColors.creamSurface)
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
        .refreshable {
            await refresh()
        }
        .topRefreshIndicator(isVisible: isRefreshing)
        .forumPageBackground()
    }
}

private struct ForumHomeCarouselView: View {
    let items: [ForumHomeCarouselItem]
    let onTap: (ForumHomeCarouselItem) -> Void

    @State private var selection = 0
    @State private var isUserInteracting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            // A full-width banner in a regular-width window (iPad, Max phones
            // in landscape) gets enormous at 2.63:1, so those widths use a
            // capped centered card with the neighboring banners peeking in
            // on both sides.
            if horizontalSizeClass == .regular {
                ForumHomePeekCarouselView(
                    items: items,
                    selection: $selection,
                    isUserInteracting: $isUserInteracting,
                    onTap: onTap
                )
            } else {
                fullWidthPager
            }
        }
        // Reduce Motion disables auto-advance entirely; the banners stay
        // swipeable by hand.
        .task(id: "\(items.map(\.id))-\(reduceMotion)") {
            guard items.count > 1, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                guard !isUserInteracting else { continue }
                withAnimation(.easeInOut(duration: 0.25)) {
                    selection = (selection + 1) % items.count
                }
            }
        }
    }

    private var fullWidthPager: some View {
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ForumCarouselImageButton(item: item, onTap: onTap)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
        .frame(maxWidth: .infinity)
        .aspectRatio(2.63, contentMode: .fit)
    }
}

/// Index arithmetic for the looping peek carousel. The strip renders the
/// banners three times; the scroll position lives in the middle copy so both
/// edges always show a real neighbor, and settles back there after every
/// gesture via an invisible congruent jump.
enum ForumHomeCarouselLoop {
    static func loopCount(itemCount: Int) -> Int {
        itemCount > 1 ? itemCount * 3 : itemCount
    }

    /// Clones flank the middle copy; they exist to be peeked at and scrolled
    /// through, never to rest on.
    static func isCloneIndex(_ index: Int, itemCount: Int) -> Bool {
        itemCount > 1 && (index < itemCount || index >= 2 * itemCount)
    }

    static func middleLoopIndex(for selection: Int, itemCount: Int) -> Int {
        guard itemCount > 1 else { return 0 }
        return itemCount + min(max(selection, 0), itemCount - 1)
    }

    /// The congruent middle-copy index to silently snap back to once a scroll
    /// settles, or `nil` when the position is already in the middle copy.
    static func recenteredIndex(from current: Int, itemCount: Int) -> Int? {
        guard itemCount > 1 else { return nil }
        guard current >= 0, current < loopCount(itemCount: itemCount) else {
            return middleLoopIndex(for: 0, itemCount: itemCount)
        }
        guard isCloneIndex(current, itemCount: itemCount) else { return nil }
        return middleLoopIndex(for: current % itemCount, itemCount: itemCount)
    }

    /// The strip index to animate to for a new selection: the shortest
    /// congruent hop, so the auto-advance +1 keeps rolling forward across the
    /// wrap and a dot tap never travels the long way around. `nil` when the
    /// current position already shows the selection.
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

/// Sizing for the regular-width peek carousel: the centered card is capped so
/// it stays banner-sized on wide iPads, and the leftover width on each side
/// shows the previous/next banner through symmetric insets.
struct ForumHomeCarouselPeekLayout: Equatable {
    static let maxCardWidth: CGFloat = 560
    static let minSideInset: CGFloat = 44
    static let cardSpacing: CGFloat = 12

    let cardWidth: CGFloat
    let sideInset: CGFloat

    /// - Parameter containerWidth: measured carousel width; `nil` before the
    ///   first layout pass, which assumes a max-width card until measured.
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
    let items: [ForumHomeCarouselItem]
    @Binding var selection: Int
    @Binding var isUserInteracting: Bool
    let onTap: (ForumHomeCarouselItem) -> Void

    @State private var containerWidth: CGFloat?
    // Index into the tripled strip, so the visible card always has a
    // neighbor on both sides; `selection` is this modulo `items.count`.
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
                            // VoiceOver should see each banner once, not three
                            // times; the middle copy is where the scroll
                            // position always settles.
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
                isUserInteracting = newPhase != .idle
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
            // A mid-gesture size-class change would otherwise leave the
            // auto-advance guard stuck on.
            isUserInteracting = false
        }
    }

    private func isCloneIndex(_ index: Int) -> Bool {
        ForumHomeCarouselLoop.isCloneIndex(index, itemCount: items.count)
    }

    private func middleLoopIndex(for selection: Int) -> Int {
        ForumHomeCarouselLoop.middleLoopIndex(for: selection, itemCount: items.count)
    }

    /// Snaps the settled position back into the middle copy of the strip
    /// without animation; the congruent card renders identical content, so
    /// the jump is invisible and the edges of the strip stay unreachable.
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
                    .fill(index == selection ? ForumColors.brownEmphasis : ForumColors.tertiaryText.opacity(0.45))
                    .frame(width: index == selection ? 18 : 6, height: 6)
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selection = index
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection)
        // The banner buttons themselves are the accessible elements; the dots
        // are a redundant visual affordance.
        .accessibilityHidden(true)
    }
}

private struct ForumCarouselImageButton: View {
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
                    Rectangle().fill(ForumColors.creamSurface)
                    ProgressView()
                }
            } failure: {
                ZStack {
                    Rectangle().fill(ForumColors.creamSurface)
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(ForumColors.secondaryText)
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
                        .foregroundStyle(ForumColors.brownEmphasis)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ForumColors.secondaryText)
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
                    // At accessibility type sizes the inline badge would
                    // squeeze the board name down to a couple of characters,
                    // so name and badge stack vertically instead.
                    titleLayout {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ForumColors.textDark)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if let todayCount {
                            Text(L10n.string("forum.home.today_count", todayCount))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(ForumColors.redAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(ForumColors.redAccent.opacity(0.12), in: Capsule())
                        }
                    }

                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(ForumColors.secondaryText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ForumColors.tertiaryText)
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
                .foregroundStyle(ForumColors.secondaryText)
        } failure: {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(ForumColors.secondaryText)
        }
        .frame(width: 38, height: 38)
        .background(ForumColors.mutedFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ForumHomeEmptyView: View {
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("forum.home.empty"), systemImage: "rectangle.stack")
        } description: {
            Text(L10n.string("forum.home.empty_message"))
        }
    }
}
