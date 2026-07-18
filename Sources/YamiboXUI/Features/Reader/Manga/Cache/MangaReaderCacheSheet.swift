import Foundation
import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderCacheSheet: View {
    @StateObject private var model: MangaReaderCacheViewModel
    @State private var queueViewModel: OfflineCacheQueueViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSelecting = false
    @State private var selectedTIDs: Set<String> = []
    @State private var isQueuePresented = false
    @State private var cacheQueueBadgeFlight: MangaReaderCacheQueueBadgeFlight?

    init(
        context: MangaLaunchContext,
        panel: MangaDirectoryPanelPresentation,
        dependencies: MangaReaderDependencies
    ) {
        _model = StateObject(
            wrappedValue: MangaReaderCacheViewModel(
                context: context,
                panel: panel,
                localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
                offlineCacheStore: dependencies.offlineCacheStore,
                offlineCacheQueueControllerProvider: {
                    await dependencies.makeOfflineCacheQueueExecutor()
                }
            )
        )
        _queueViewModel = State(initialValue: OfflineCacheQueueViewModel(dependencies: dependencies.account))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = model.errorMessage {
                        MangaReaderCacheErrorBanner(message: errorMessage)
                    }

                    MangaReaderCacheChapterSection(
                        rows: model.rows,
                        isSelecting: $isSelecting,
                        selectedTIDs: $selectedTIDs,
                        isAllSelected: selectionState.isAllSelected,
                        onToggleAll: toggleAll
                    )
                }
                .padding(16)
            }
            .background(YamiboColors.SystemSurface.groupedBackground)
            .navigationTitle(
                isSelecting
                    ? L10n.string("manga.offline_cache.selected_count", selectedTIDs.count)
                    : L10n.string("manga.offline_cache.title")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("common.close"))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    ReaderCacheQueueToolbarButton(
                        entryCount: model.offlineCacheQueueEntryCount,
                        action: {
                            isQueuePresented = true
                        }
                    ) { isActive in
                        ReaderCacheDownloadQueueIcon(isActive: isActive)
                            .anchorPreference(key: MangaReaderCacheQueueButtonAnchorKey.self, value: .bounds) { $0 }
                    }
                }

                if isSelecting && usesSystemSelectionBottomToolbar {
                    ToolbarItem(placement: .bottomBar) {
                        SelectionBottomToolbar(actions: selectionActions)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(actions: selectionActions)
                        .selectionBottomToolbarCapsule()
                }
            }
            .sheet(isPresented: $isQueuePresented) {
                OfflineCacheQueueSheet(viewModel: queueViewModel)
            }
            .task {
                await model.load()
            }
            .refreshable {
                await model.refreshRows()
            }
            .onChange(of: model.allChapterTIDs) { _, validTIDs in
                selectedTIDs.formIntersection(validTIDs)
            }
            .sensoryFeedback(.selection, trigger: selectedTIDs)
            .alert(
                L10n.string("manga.offline_cache.add_favorite_title"),
                isPresented: .presentation(
                    isPresented: { model.prompt != nil },
                    clearOnDismiss: { model.clearPrompt() }
                ),
                presenting: model.prompt
            ) { _ in
                Button(L10n.string("common.ok"), role: .cancel) {
                    model.clearPrompt()
                }
            } message: { prompt in
                switch prompt {
                case let .addFavorite(title):
                    Text(L10n.string("manga.offline_cache.add_favorite_message", title))
                }
            }
        }
        .overlayPreferenceValue(MangaReaderCacheQueueButtonAnchorKey.self) { queueButtonAnchor in
            Color.clear
                .overlayPreferenceValue(SelectionBottomToolbarActionAnchorKey.self) { actionAnchors in
                    GeometryReader { proxy in
                        MangaReaderCacheQueueBadgeFlightLayer(
                            flight: cacheQueueBadgeFlight,
                            sourceFrame: actionAnchors["cache"].map { proxy[$0] },
                            destinationFrame: queueButtonAnchor.map { proxy[$0] },
                            containerSize: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets,
                            onFinished: clearCacheQueueBadgeFlight
                        )
                    }
                    .allowsHitTesting(false)
                }
        }
    }

    private var selectionState: ReaderCacheSelectionState {
        model.selectionState(for: selectedTIDs)
    }

    private var selectionActions: [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "cache",
                title: L10n.string("reader.cache_action.cache"),
                systemImage: "square.and.arrow.down",
                isEnabled: selectionState.canCache,
                action: cacheSelection
            ),
            SelectionToolbarAction(
                id: "delete",
                title: L10n.string("common.delete"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: selectionState.canDelete,
                action: deleteSelection
            )
        ]
    }

    private func toggleAll() {
        if selectionState.isAllSelected {
            selectedTIDs = []
        } else {
            selectedTIDs = model.allChapterTIDs
        }
    }

    private func cacheSelection() {
        let targets = selectedTIDs
        let uncachedSelectionCount = selectionState.uncachedSelectedTIDs.count
        Task { @MainActor in
            await model.cacheSelected(tids: targets)
            if model.errorMessage == nil, model.prompt == nil {
                cacheQueueBadgeFlight = MangaReaderCacheQueueBadgeFlight(count: uncachedSelectionCount)
                await Task.yield()
            }
            exitSelectionModeIfActionFinished()
        }
    }

    private func deleteSelection() {
        let targets = selectedTIDs
        Task {
            await model.deleteSelected(tids: targets)
            exitSelectionModeIfActionFinished()
        }
    }

    @MainActor
    private func exitSelectionModeIfActionFinished() {
        guard model.errorMessage == nil else { return }
        isSelecting = false
        selectedTIDs = []
    }

    @MainActor
    private func clearCacheQueueBadgeFlight(_ id: UUID) {
        guard cacheQueueBadgeFlight?.id == id else { return }
        cacheQueueBadgeFlight = nil
    }
}

private struct MangaReaderCacheQueueBadgeFlight: Identifiable, Equatable {
    let id = UUID()
    let count: Int
}

/// The nav-bar queue button's own frame, for the badge-flight destination —
/// the flight's source (the bottom bar's "cache" action) is tracked by the
/// shared `SelectionBottomToolbarActionAnchorKey` instead, since that button
/// now lives inside the shared `SelectionBottomToolbar`.
private struct MangaReaderCacheQueueButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct MangaReaderCacheQueueBadgeFlightLayer: View {
    let flight: MangaReaderCacheQueueBadgeFlight?
    let sourceFrame: CGRect?
    let destinationFrame: CGRect?
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let onFinished: @MainActor (UUID) -> Void

    var body: some View {
        if let flight {
            MangaReaderCacheQueueBadgeFlightView(
                flight: flight,
                source: sourcePoint,
                destination: destinationPoint,
                onFinished: onFinished
            )
        }
    }

    private var sourcePoint: CGPoint {
        if let sourceFrame {
            return CGPoint(x: sourceFrame.midX, y: max(12, sourceFrame.minY - 12))
        }

        return CGPoint(
            x: max(34, containerSize.width / 2 - 41),
            y: max(28, containerSize.height - safeAreaInsets.bottom - 76)
        )
    }

    private var destinationPoint: CGPoint {
        if let destinationFrame {
            return CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)
        }

        return CGPoint(
            x: max(24, containerSize.width - 42),
            y: max(24, safeAreaInsets.top + 24)
        )
    }
}

private struct MangaReaderCacheQueueBadgeFlightView: View {
    private static let flightDurationMilliseconds: UInt64 = 720
    private static let reduceMotionDurationMilliseconds: UInt64 = 180

    let flight: MangaReaderCacheQueueBadgeFlight
    let source: CGPoint
    let destination: CGPoint
    let onFinished: @MainActor (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hasArrived = false
    @State private var didStart = false

    var body: some View {
        MangaReaderCacheQueueFlightBadge(count: flight.count)
            .scaleEffect(hasArrived ? 0.55 : 1)
            .opacity(hasArrived ? 0 : 1)
            .position(displayedPosition)
            .accessibilityHidden(true)
            .onAppear {
                startFlight()
            }
            .id(flight.id)
    }

    private var displayedPosition: CGPoint {
        if accessibilityReduceMotion {
            return source
        }
        return hasArrived ? destination : source
    }

    @MainActor
    private func startFlight() {
        guard !didStart else { return }
        didStart = true

        withAnimation(animation) {
            hasArrived = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(removalDelayMilliseconds))
            onFinished(flight.id)
        }
    }

    private var animation: Animation {
        if accessibilityReduceMotion {
            return .easeOut(duration: 0.18)
        }
        return .timingCurve(0.22, 0.86, 0.18, 1.0, duration: 0.72)
    }

    private var removalDelayMilliseconds: UInt64 {
        accessibilityReduceMotion
            ? Self.reduceMotionDurationMilliseconds
            : Self.flightDurationMilliseconds
    }
}

private struct MangaReaderCacheQueueFlightBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, count < 10 ? 0 : 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(Color.red))
            .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
    }
}


private struct MangaReaderCacheErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(YamiboColors.SystemSurface.secondaryGroupedBackground)
            )
    }
}

private struct MangaReaderCacheChapterSection: View {
    let rows: [MangaReaderCacheRow]
    @Binding var isSelecting: Bool
    @Binding var selectedTIDs: Set<String>
    let isAllSelected: Bool
    let onToggleAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReaderCacheSelectionHeader(
                sectionTitle: L10n.string("manga.offline_cache.chapter_section"),
                isSelecting: isSelecting,
                isAllSelected: isAllSelected,
                isEmpty: rows.isEmpty,
                onToggleAll: onToggleAll,
                onToggleSelectionMode: toggleSelectionMode
            )
            .frame(height: 38, alignment: .center)

            if rows.isEmpty {
                ContentUnavailableView(L10n.string("manga.no_chapters"), systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { row in
                        MangaReaderCacheRowView(
                            row: row,
                            isSelecting: isSelecting,
                            isSelected: selectedTIDs.contains(row.id),
                            onToggleSelection: {
                                toggleSelection(row.id)
                            }
                        )
                    }
                }
            }
        }
    }

    private func toggleSelectionMode() {
        if isSelecting {
            isSelecting = false
            selectedTIDs = []
        } else {
            isSelecting = true
        }
    }

    private func toggleSelection(_ tid: String) {
        if !isSelecting {
            isSelecting = true
            selectedTIDs.insert(tid)
            return
        }

        if selectedTIDs.contains(tid) {
            selectedTIDs.remove(tid)
        } else {
            selectedTIDs.insert(tid)
        }
    }
}

private struct MangaReaderCacheRowView: View {
    let row: MangaReaderCacheRow
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(MangaChapterDisplayFormatter.displayNumber(for: row.chapter))
                .font(.caption.weight(.bold))
                .foregroundStyle(numberColor)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.chapter.rawTitle)
                    .font(.subheadline)
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MangaReaderCacheStateBadge(state: row.state, isDimmed: dimming.isDimmed)
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected) {
            onToggleSelection()
        }
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private var titleColor: Color {
        dimming.titleColor
    }

    private var numberColor: Color {
        dimming.secondaryColor
    }
}

private struct MangaReaderCacheStateBadge: View {
    let state: MangaOfflineCacheState
    let isDimmed: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var title: String {
        switch state {
        case .cached:
            L10n.string("reader.cached")
        case .uncached:
            L10n.string("manga.offline_cache.uncached")
        case .caching:
            L10n.string("manga.offline_cache.caching")
        }
    }

    private var systemImage: String {
        switch state {
        case .cached:
            "checkmark.seal.fill"
        case .uncached:
            "icloud"
        case .caching:
            "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        if isDimmed {
            return Color.secondary.opacity(0.55)
        }
        switch state {
        case .cached:
            return Color.green
        case .uncached:
            return Color.secondary
        case .caching:
            return Color.orange
        }
    }
}

#endif
