import Foundation
import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderDownloadSheet: View {
    @StateObject private var model: MangaReaderDownloadViewModel
    @State private var queueViewModel: DownloadQueueViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSelecting = false
    @State private var selectedTIDs: Set<String> = []
    @State private var isQueuePresented = false
    @State private var downloadQueueBadgeFlight: MangaReaderDownloadQueueBadgeFlight?

    init(
        context: MangaLaunchContext,
        panel: MangaDirectoryPanelPresentation,
        dependencies: MangaReaderDependencies
    ) {
        _model = StateObject(
            wrappedValue: MangaReaderDownloadViewModel(
                context: context,
                panel: panel,
                localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
                downloadStore: dependencies.downloadStore,
                downloadQueueControllerProvider: {
                    await dependencies.makeDownloadQueueExecutor()
                }
            )
        )
        _queueViewModel = State(initialValue: DownloadQueueViewModel(dependencies: dependencies.downloadQueue))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = model.errorMessage {
                        MangaReaderDownloadErrorBanner(message: errorMessage, details: model.errorDetails)
                    }

                    ReaderDownloadSelectionSection(
                        rows: model.rows,
                        sectionTitle: L10n.string("manga.download.chapter_section"),
                        emptyTitle: L10n.string("manga.no_chapters"),
                        emptySystemImage: "books.vertical",
                        isSelecting: $isSelecting,
                        selection: $selectedTIDs,
                        isAllSelected: selectionState.isAllSelected,
                        onToggleAll: toggleAll
                    ) { row, isSelected in
                        MangaReaderDownloadRowView(
                            row: row, isSelecting: isSelecting, isSelected: isSelected
                        )
                    }
                }
                .padding(16)
            }
            .background(YamiboColors.SystemSurface.groupedBackground)
            .navigationTitle(
                isSelecting
                    ? L10n.string("manga.download.selected_count", selectedTIDs.count)
                    : L10n.string("manga.download.title")
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
                    ReaderDownloadQueueToolbarButton(
                        entryCount: model.downloadQueueEntryCount,
                        action: {
                            isQueuePresented = true
                        }
                    ) { isActive in
                        ReaderDownloadQueueIcon(isActive: isActive)
                            .anchorPreference(key: MangaReaderDownloadQueueButtonAnchorKey.self, value: .bounds) { $0 }
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
                DownloadQueueSheet(viewModel: queueViewModel)
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
            .failureAlert(
                L10n.string("manga.download.add_favorite_title"),
                message: favoriteRequiredMessage,
                isPresented: .presentation(
                    isPresented: { model.prompt != nil },
                    clearOnDismiss: { model.clearPrompt() }
                )
            ) {
                Button(L10n.string("common.ok"), role: .cancel) {
                    model.clearPrompt()
                }
            }
        }
        .overlayPreferenceValue(MangaReaderDownloadQueueButtonAnchorKey.self) { queueButtonAnchor in
            Color.clear
                .overlayPreferenceValue(SelectionBottomToolbarActionAnchorKey.self) { actionAnchors in
                    GeometryReader { proxy in
                        MangaReaderDownloadQueueBadgeFlightLayer(
                            flight: downloadQueueBadgeFlight,
                            sourceFrame: actionAnchors["download"].map { proxy[$0] },
                            destinationFrame: queueButtonAnchor.map { proxy[$0] },
                            containerSize: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets,
                            onFinished: clearDownloadQueueBadgeFlight
                        )
                    }
                    .allowsHitTesting(false)
                }
        }
    }

    private var selectionState: ReaderDownloadSelectionState {
        model.selectionState(for: selectedTIDs)
    }

    private var favoriteRequiredMessage: String? {
        guard case let .addFavorite(title) = model.prompt else { return nil }
        return L10n.string("manga.download.add_favorite_message", title)
    }

    private var selectionActions: [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "download",
                title: L10n.string("reader.download_action.download"),
                systemImage: "square.and.arrow.down",
                isEnabled: selectionState.canDownload,
                action: downloadSelection
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

    private func downloadSelection() {
        let targets = selectedTIDs
        let notDownloadedSelectionCount = selectionState.notDownloadedSelectedTIDs.count
        Task { @MainActor in
            await model.downloadSelected(tids: targets)
            if model.errorMessage == nil, model.prompt == nil {
                downloadQueueBadgeFlight = MangaReaderDownloadQueueBadgeFlight(count: notDownloadedSelectionCount)
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
    private func clearDownloadQueueBadgeFlight(_ id: UUID) {
        guard downloadQueueBadgeFlight?.id == id else { return }
        downloadQueueBadgeFlight = nil
    }
}

private struct MangaReaderDownloadQueueBadgeFlight: Identifiable, Equatable {
    let id = UUID()
    let count: Int
}

/// The nav-bar queue button's own frame, for the badge-flight destination —
/// the flight's source (the bottom bar's "download" action) is tracked by the
/// shared `SelectionBottomToolbarActionAnchorKey` instead, since that button
/// now lives inside the shared `SelectionBottomToolbar`.
private struct MangaReaderDownloadQueueButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct MangaReaderDownloadQueueBadgeFlightLayer: View {
    let flight: MangaReaderDownloadQueueBadgeFlight?
    let sourceFrame: CGRect?
    let destinationFrame: CGRect?
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let onFinished: @MainActor (UUID) -> Void

    var body: some View {
        if let flight {
            MangaReaderDownloadQueueBadgeFlightView(
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

private struct MangaReaderDownloadQueueBadgeFlightView: View {
    private static let flightDurationMilliseconds: UInt64 = 720
    private static let reduceMotionDurationMilliseconds: UInt64 = 180

    let flight: MangaReaderDownloadQueueBadgeFlight
    let source: CGPoint
    let destination: CGPoint
    let onFinished: @MainActor (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hasArrived = false
    @State private var didStart = false

    var body: some View {
        MangaReaderDownloadQueueFlightBadge(count: flight.count)
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

private struct MangaReaderDownloadQueueFlightBadge: View {
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


private struct MangaReaderDownloadErrorBanner: View {
    let message: String
    let details: LoadFailureDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(message, systemImage: "exclamationmark.triangle")
            LoadFailureDetailsButton(details: details, message: message)
        }
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

private struct MangaReaderDownloadRowView: View {
    let row: MangaReaderDownloadRow
    let isSelecting: Bool
    let isSelected: Bool

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

            ReaderDownloadStateBadge(
                state: row.state.downloadDisplayState,
                notDownloadedTitle: L10n.string("manga.download.not_downloaded"),
                downloadingTitle: L10n.string("manga.download.downloading"),
                isDimmed: dimming.isDimmed
            )
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

private extension MangaDownloadState {
    var downloadDisplayState: ReaderDownloadDisplayState {
        switch self {
        case .downloaded: .downloaded
        case .notDownloaded: .notDownloaded
        case .downloading: .downloading
        }
    }
}

#endif
