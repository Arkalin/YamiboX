import SwiftUI
import YamiboXCore

/// Sheet shell for contexts without a navigation stack of their own (the
/// full-screen readers' cache sheets). The Mine tab pushes
/// `OfflineCacheQueueScreen` directly instead.
struct OfflineCacheQueueSheet: View {
    let viewModel: OfflineCacheQueueViewModel

    var body: some View {
        NavigationStack {
            OfflineCacheQueueScreen(viewModel: viewModel, showsCloseButton: true)
        }
    }
}

struct OfflineCacheQueueScreen: View {
    let viewModel: OfflineCacheQueueViewModel
    var showsCloseButton = false

    @Environment(\.dismiss) private var dismiss
    @State private var selectedGroupID: OfflineCacheGroupID?

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let failure = viewModel.loadFailure {
                        LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                            Task { await viewModel.refresh() }
                        }
                    }
                    if viewModel.isEmpty && viewModel.loadFailure == nil && !viewModel.isLoading {
                        OfflineCacheQueueEmptyState()
                    } else {
                        if viewModel.showsControls {
                            OfflineCacheQueueControls(viewModel: viewModel)
                        }

                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.groups) { group in
                                OfflineCacheQueueOwnerRow(
                                    group: group,
                                    runState: viewModel.runState,
                                    isSelecting: viewModel.isSelectionMode,
                                    isSelected: viewModel.isOwnerSelected(id: group.id),
                                    open: {
                                        viewModel.setSelectionMode(false)
                                        selectedGroupID = group.id
                                    },
                                    toggleSelection: {
                                        viewModel.toggleOwnerSelection(id: group.id)
                                    },
                                    cancel: {
                                        Task {
                                            await viewModel.cancelOwnerGroup(id: group.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(YamiboColors.SystemSurface.groupedBackground)
            .offlineCacheQueueFailureAlert(viewModel, isActive: selectedGroupID == nil)
            .navigationTitle(
                viewModel.isSelectionMode
                    ? L10n.string("mine.offline_queue.selected_count", viewModel.selectedWorkCount)
                    : L10n.string("mine.download_queue")
            )
            .task {
                await viewModel.load()
            }
            .refreshable {
                await viewModel.refresh()
            }
            .navigationDestination(item: $selectedGroupID) { groupID in
                OfflineCacheQueueOwnerScreen(
                    viewModel: viewModel,
                    groupID: groupID
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if viewModel.isSelectionMode {
                        OfflineCacheQueueSelectAllButton(viewModel: viewModel)
                    } else if showsCloseButton {
                        Button(L10n.string("common.close")) {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if !viewModel.isEmpty {
                        SelectionModeToggleButton(
                            isSelecting: viewModel.isSelectionMode,
                            isDisabled: viewModel.isCommandRunning
                        ) {
                            viewModel.setSelectionMode(!viewModel.isSelectionMode)
                        }
                    }
                }

                if viewModel.isSelectionMode && usesSystemSelectionBottomToolbar {
                    ToolbarItem(placement: .bottomBar) {
                        SelectionBottomToolbar(actions: OfflineCacheQueueSelectionActions.cancel(viewModel: viewModel))
                    }
                }
            }
            .toolbar(viewModel.isSelectionMode ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.isSelectionMode && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(actions: OfflineCacheQueueSelectionActions.cancel(viewModel: viewModel))
                        .selectionBottomToolbarCapsule()
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.isEmpty {
                    ProgressView()
                }
            }
            .sensoryFeedback(.selection, trigger: viewModel.selectedWorkIDs)
    }
}

private struct OfflineCacheQueueSelectAllButton: View {
    let viewModel: OfflineCacheQueueViewModel
    var groupID: OfflineCacheGroupID? = nil

    var body: some View {
        SelectAllToolbarButton(
            isSelectionComplete: viewModel.isWorkSelectionComplete(groupID: groupID),
            isDisabled: viewModel.isEmpty
        ) {
            viewModel.toggleAllWorks(groupID: groupID)
        }
    }
}

/// Builds the selection-mode bottom bar's single "cancel selected" action —
/// rendering is delegated to the shared `SelectionBottomToolbar`.
@MainActor
private enum OfflineCacheQueueSelectionActions {
    static func cancel(viewModel: OfflineCacheQueueViewModel) -> [SelectionToolbarAction] {
        let canCancel = !viewModel.selectedWorkIDs.isEmpty
            && !viewModel.isCommandRunning
        return [
            SelectionToolbarAction(
                id: "cancel",
                title: L10n.string("mine.offline_queue.cancel_download"),
                systemImage: "xmark.circle",
                role: .destructive,
                isEnabled: canCancel,
                accessibilityLabel: L10n.string(
                    "mine.offline_queue.cancel_selected_format",
                    viewModel.selectedWorkCount
                ),
                action: {
                    Task { await viewModel.cancelSelectedWorks() }
                }
            )
        ]
    }
}

private struct OfflineCacheQueueControls: View {
    let viewModel: OfflineCacheQueueViewModel
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: viewModel.runState == .running ? "arrow.down.circle.fill" : "pause.circle.fill")
                    .font(.title)
                    .foregroundStyle(appTheme.controlAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(viewModel.runState == .running
                        ? "mine.offline_queue.running" : "mine.offline_queue.paused"))
                        .font(.headline)
                    Text(L10n.string("mine.offline_queue.chapter_count_format", viewModel.entryCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Button {
                Task {
                    if viewModel.runState == .running {
                        await viewModel.pauseQueue()
                    } else {
                        await viewModel.continueQueue()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isCommandRunning { ProgressView() }
                    Label(controlTitle, systemImage: controlImage)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(appTheme.controlAccent)
            .disabled(viewModel.isCommandRunning)
        }
        .padding(16)
        .background(YamiboColors.SystemSurface.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controlTitle: String {
        viewModel.runState == .running
            ? L10n.string("mine.offline_queue.pause_all")
            : L10n.string("mine.offline_queue.continue_all")
    }

    private var controlImage: String {
        viewModel.runState == .running ? "pause.fill" : "play.fill"
    }
}

private struct OfflineCacheQueueOwnerRow: View {
    let group: OfflineCacheQueueOwnerGroup
    let runState: OfflineCacheQueueRunState
    let isSelecting: Bool
    let isSelected: Bool
    let open: () -> Void
    let toggleSelection: () -> Void
    let cancel: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelecting ? (isSelected ? "checkmark.circle.fill" : "circle")
                : (group.readerKind == .manga ? "photo.on.rectangle.angled" : "text.book.closed.fill"))
                .font(.title3)
                .foregroundStyle(dimming.emphasis(appTheme.controlAccent))
                .frame(width: 40, height: 48)
                .background(dimming.emphasis(appTheme.controlAccent).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.ownerName)
                            .font(.headline)
                            .foregroundStyle(dimming.titleColor)
                            .lineLimit(2)

                        Text(L10n.string("mine.offline_queue.chapter_count_format", group.chapterCount))
                            .font(.caption)
                            .foregroundStyle(dimming.secondaryColor)
                    }

                    Spacer(minLength: 8)

                    Text(group.percentageText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(dimming.secondaryColor)
                        .lineLimit(1)
                }

                OfflineCacheQueueProgress(
                    fraction: group.progressFraction,
                    progressText: group.progressText,
                    speedText: runState == .running ? group.currentSpeedText : nil,
                    failureText: group.failureStatusText,
                    isDimmed: dimming.isDimmed
                )
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .opacity(isSelecting ? 0 : 1)
                .accessibilityHidden(isSelecting)
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected, onTap: rowAction)
        .contextMenu {
            if !isSelecting {
                Button(role: .destructive, action: cancel) {
                    Label(L10n.string("mine.offline_queue.cancel_download"), systemImage: "xmark.circle")
                }
            }
        }
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private func rowAction() {
        if isSelecting {
            toggleSelection()
        } else {
            open()
        }
    }
}

/// Drill-down detail for one owner's queued chapters, pushed onto the
/// enclosing navigation stack (system back replaces the old sheet-on-sheet
/// close button).
private struct OfflineCacheQueueOwnerScreen: View {
    let viewModel: OfflineCacheQueueViewModel
    let groupID: OfflineCacheGroupID
    @Environment(\.dismiss) private var dismiss

    private var group: OfflineCacheQueueOwnerGroup? {
        viewModel.groups.first { $0.id == groupID }
    }

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let group {
                        if viewModel.showsControls {
                            OfflineCacheQueueControls(viewModel: viewModel)
                        }

                        LazyVStack(spacing: 10) {
                            ForEach(group.chapters) { chapter in
                                OfflineCacheQueueChapterRowView(
                                    chapter: chapter,
                                    runState: viewModel.runState,
                                    isCommandRunning: viewModel.isCommandRunning,
                                    isSelecting: viewModel.isSelectionMode,
                                    isSelected: viewModel.selectedWorkIDs.contains(chapter.id),
                                    toggleSelection: {
                                        viewModel.toggleWorkSelection(chapter.id)
                                    },
                                    cancel: {
                                        Task {
                                            await viewModel.cancelChapter(chapter.id)
                                            dismissIfGroupIsEmpty()
                                        }
                                    }
                                )
                            }
                        }
                    } else if viewModel.loadFailure == nil {
                        OfflineCacheQueueEmptyState()
                    }
                    if let failure = viewModel.loadFailure {
                        LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                            Task { await viewModel.refresh() }
                        }
                    }
                }
                .padding(16)
            }
            .background(YamiboColors.SystemSurface.groupedBackground)
            .navigationTitle(
                viewModel.isSelectionMode
                    ? L10n.string("mine.offline_queue.selected_count", viewModel.selectedWorkCount)
                    : (group?.title ?? L10n.string("mine.download_queue"))
            )
            .task {
                viewModel.setSelectionMode(false)
                await viewModel.refresh()
                dismissIfGroupIsEmpty()
            }
            .refreshable {
                await viewModel.refresh()
                dismissIfGroupIsEmpty()
            }
            .onChange(of: viewModel.entryCount) {
                dismissIfGroupIsEmpty()
            }
            .onDisappear {
                viewModel.setSelectionMode(false)
            }
            .toolbar {
                if viewModel.isSelectionMode {
                    ToolbarItem(placement: .cancellationAction) {
                        OfflineCacheQueueSelectAllButton(
                            viewModel: viewModel,
                            groupID: groupID
                        )
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if group != nil {
                        SelectionModeToggleButton(
                            isSelecting: viewModel.isSelectionMode,
                            isDisabled: viewModel.isCommandRunning
                        ) {
                            viewModel.setSelectionMode(!viewModel.isSelectionMode)
                        }
                    }
                }

                if viewModel.isSelectionMode && usesSystemSelectionBottomToolbar {
                    ToolbarItem(placement: .bottomBar) {
                        SelectionBottomToolbar(actions: OfflineCacheQueueSelectionActions.cancel(viewModel: viewModel))
                    }
                }
            }
            .toolbar(viewModel.isSelectionMode ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.isSelectionMode && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(actions: OfflineCacheQueueSelectionActions.cancel(viewModel: viewModel))
                        .selectionBottomToolbarCapsule()
                }
            }
            .overlay {
                if viewModel.isLoading && group == nil {
                    ProgressView()
                }
            }
            .sensoryFeedback(.selection, trigger: viewModel.selectedWorkIDs)
            .offlineCacheQueueFailureAlert(viewModel)
    }

    private func dismissIfGroupIsEmpty() {
        if group == nil, viewModel.loadFailure == nil {
            dismiss()
        }
    }
}

private extension View {
    func offlineCacheQueueFailureAlert(_ model: OfflineCacheQueueViewModel, isActive: Bool = true) -> some View {
        failureAlert(
            L10n.string("common.operation_failed"), message: model.errorMessage, details: model.errorDetails,
            isPresented: Binding(
                get: { isActive && model.errorMessage != nil },
                set: { if !$0, isActive { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.string("common.ok"), role: .cancel) { model.errorMessage = nil }
        }
    }
}

private struct OfflineCacheQueueChapterRowView: View {
    let chapter: OfflineCacheQueueChapterRow
    let runState: OfflineCacheQueueRunState
    let isCommandRunning: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void
    let cancel: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(dimming.emphasis(appTheme.controlAccent))
                        .accessibilityHidden(true)
                }
                Text(chapter.title)
                    .font(.headline)
                    .foregroundStyle(dimming.titleColor)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(chapter.percentageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(dimming.secondaryColor)
                    .lineLimit(1)
            }

            OfflineCacheQueueProgress(
                fraction: chapter.progressFraction,
                progressText: chapter.progressText,
                speedText: runState == .running ? chapter.speedText : nil,
                failureText: chapter.failureStatusText,
                isDimmed: dimming.isDimmed
            )

            HStack {
                Label(statusTitle, systemImage: statusImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dimming.emphasis(chapter.state == .failed ? .red : appTheme.controlAccent))
                Spacer(minLength: 8)
                if !isSelecting {
                    Button(role: .destructive, action: cancel) {
                        Text(L10n.string("mine.offline_queue.cancel_download"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isCommandRunning)
                }
            }
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected, onTap: selectionAction)
    }

    private var selectionAction: (() -> Void)? {
        guard isSelecting else { return nil }
        return { toggleSelection() }
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private var statusTitle: String {
        if chapter.state == .failed { return L10n.string("settings.offline_cache.state.failed") }
        if runState != .running { return L10n.string("settings.offline_cache.state.paused") }
        return L10n.string(chapter.state == .running
            ? "settings.offline_cache.state.running" : "settings.offline_cache.state.queued")
    }

    private var statusImage: String {
        if chapter.state == .failed { return "exclamationmark.circle" }
        if runState != .running { return "pause.circle" }
        return chapter.state == .running ? "arrow.down.circle" : "clock"
    }
}

private struct OfflineCacheQueueProgress: View {
    let fraction: Double
    let progressText: String
    let speedText: String?
    let failureText: String?
    let isDimmed: Bool
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction)
                .tint(isDimmed ? Color.secondary : appTheme.controlAccent)
                .accessibilityLabel(progressText)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(progressText)
                    Spacer(minLength: 0)
                    if let speedText { Text(speedText).monospacedDigit() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(progressText)
                    if let speedText { Text(speedText).monospacedDigit() }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let failureText {
                Label(failureText, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isDimmed ? Color.secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OfflineCacheQueueEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("mine.offline_queue.empty_title"), systemImage: "arrow.down.circle")
        } description: {
            Text(L10n.string("mine.offline_queue.empty_message"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
