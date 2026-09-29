import SwiftUI
import YamiboXCore

/// Sheet shell for contexts without a navigation stack of their own (the
/// full-screen readers' download sheets).
struct DownloadQueueSheet: View {
    let viewModel: DownloadQueueViewModel
    let management: DownloadManagementViewModel

    var body: some View {
        NavigationStack {
            DownloadsScreen(initialPage: .queue, management: management, queue: viewModel, showsCloseButton: true)
        }
    }
}

struct DownloadQueueScreen: View {
    let viewModel: DownloadQueueViewModel
    let openManagement: () -> Void

    @State private var selectedGroupID: DownloadGroupID?

    var body: some View {
        List {
            Group {
                if let failure = viewModel.loadFailure {
                    LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                        Task { await viewModel.refresh() }
                    }
                }
                if viewModel.isEmpty && viewModel.loadFailure == nil && !viewModel.isLoading {
                    DownloadQueueEmptyState()
                } else {
                    Section {
                        ForEach(viewModel.groups) { group in
                            DownloadQueueOwnerRow(
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
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 12, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if viewModel.showsControls {
                DownloadQueueControls(viewModel: viewModel)
            }
        }
        .yamiboInlineNavigationTitleDisplayMode()
        .navigationBarBackButtonHidden(viewModel.isSelectionMode)
        .downloadQueueFailureAlert(viewModel, isActive: selectedGroupID == nil)
        .navigationTitle(
            viewModel.isSelectionMode
                ? L10n.string("mine.download_queue.selected_count", viewModel.selectedWorkCount)
                : L10n.string("mine.download_queue")
        )
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .navigationDestination(item: $selectedGroupID) { groupID in
            DownloadQueueOwnerScreen(
                viewModel: viewModel,
                groupID: groupID
            )
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.isSelectionMode {
                    DownloadQueueSelectAllButton(viewModel: viewModel)
                }
            }

            if !viewModel.isSelectionMode {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("settings.download.title"), action: openManagement)
                        .disabled(viewModel.isCommandRunning)
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
                    SelectionBottomToolbar(actions: DownloadQueueSelectionActions.cancel(viewModel: viewModel))
                }
            }
        }
        .toolbar(viewModel.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isSelectionMode && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(actions: DownloadQueueSelectionActions.cancel(viewModel: viewModel))
                    .selectionBottomToolbarCapsule()
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.isEmpty {
                ProgressView()
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.selectedWorkIDs)
        .onDisappear { viewModel.setSelectionMode(false) }
    }
}

private struct DownloadQueueSelectAllButton: View {
    let viewModel: DownloadQueueViewModel
    var groupID: DownloadGroupID? = nil

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
private enum DownloadQueueSelectionActions {
    static func cancel(viewModel: DownloadQueueViewModel) -> [SelectionToolbarAction] {
        let canCancel =
            !viewModel.selectedWorkIDs.isEmpty
            && !viewModel.isCommandRunning
        return [
            SelectionToolbarAction(
                id: "cancel",
                title: L10n.string("mine.download_queue.cancel_download"),
                systemImage: "xmark.circle",
                role: .destructive,
                isEnabled: canCancel,
                accessibilityLabel: L10n.string(
                    "mine.download_queue.cancel_selected_format",
                    viewModel.selectedWorkCount
                ),
                action: {
                    Task { await viewModel.cancelSelectedWorks() }
                }
            )
        ]
    }
}

private struct DownloadQueueControls: View {
    let viewModel: DownloadQueueViewModel
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    summary
                    actions
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        summary
                        Spacer(minLength: 0)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        summary
                        actions
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("downloads.queue.controls")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.string(viewModel.runState == .running ? "settings.download.state.running" : "settings.download.state.paused"))
                .font(.subheadline.weight(.semibold))
            Text(viewModel.failedCount > 0
                ? L10n.string("downloads.queue_counts_failed", viewModel.entryCount, viewModel.failedCount)
                : L10n.string("settings.download.entry_count_format", viewModel.entryCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if viewModel.failedCount > 0 && viewModel.runState == .running {
                Button {
                    Task { await viewModel.continueQueue() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 24, height: 32)
                }
                .accessibilityLabel(L10n.string("downloads.retry_continue_all"))
                .frame(minWidth: 44, minHeight: 44)
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
                Group {
                    if viewModel.isCommandRunning {
                        ProgressView()
                    } else {
                        Image(systemName: viewModel.runState == .running ? "pause.fill" : "play.fill")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 24, height: 32)
            }
            .accessibilityLabel(controlAccessibilityLabel)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(appTheme.controlAccent)
        .disabled(viewModel.isCommandRunning)
    }

    private var controlAccessibilityLabel: String {
        viewModel.runState == .running
            ? L10n.string("mine.download_queue.pause_all")
            : L10n.string(viewModel.failedCount > 0 ? "downloads.retry_continue_all" : "mine.download_queue.continue_all")
    }
}

private struct DownloadQueueOwnerRow: View {
    let group: DownloadQueueOwnerGroup
    let runState: DownloadQueueRunState
    let isSelecting: Bool
    let isSelected: Bool
    let open: () -> Void
    let toggleSelection: () -> Void
    let cancel: () -> Void
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(
                systemName: isSelecting
                    ? (isSelected ? "checkmark.circle.fill" : "circle")
                    : (group.readerKind == .attachment ? "paperclip" : (group.readerKind == .manga ? "photo.on.rectangle.angled" : "text.book.closed.fill"))
            )
            .font(.system(size: 20))
            .foregroundStyle(dimming.emphasis(appTheme.controlAccent))
            .frame(width: 28, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.ownerName)
                            .font(.headline)
                            .foregroundStyle(dimming.titleColor)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

                        Text(L10n.string("mine.download_queue.chapter_count_format", group.chapterCount))
                            .font(.caption)
                            .foregroundStyle(dimming.secondaryColor)
                    }

                    Spacer(minLength: 8)

                    Text(group.percentageText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(dimming.secondaryColor)
                        .lineLimit(1)
                }

                DownloadQueueProgress(
                    fraction: group.progressFraction,
                    progressText: group.progressText,
                    speedText: runState == .running && group.chapters.contains(where: { $0.state == .running })
                        ? group.currentSpeedText : nil,
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
        .downloadListRow(isSelected: isSelected, action: rowAction)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button(role: .destructive, action: cancel) {
                    Label(L10n.string("mine.download_queue.cancel_download"), systemImage: "xmark.circle")
                }
            }
        }
        .contextMenu {
            if !isSelecting {
                Button(role: .destructive, action: cancel) {
                    Label(L10n.string("mine.download_queue.cancel_download"), systemImage: "xmark.circle")
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
private struct DownloadQueueOwnerScreen: View {
    let viewModel: DownloadQueueViewModel
    let groupID: DownloadGroupID
    @Environment(\.dismiss) private var dismiss

    private var group: DownloadQueueOwnerGroup? {
        viewModel.groups.first { $0.id == groupID }
    }

    var body: some View {
        List {
            Group {
                if let group {
                    Section {
                        Text(L10n.string("mine.download_queue.chapter_count_format", group.chapterCount))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    Section {
                        ForEach(group.chapters) { chapter in
                            DownloadQueueChapterRowView(
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
                    DownloadQueueEmptyState()
                }
                if let failure = viewModel.loadFailure {
                    LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                        Task { await viewModel.refresh() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .yamiboInlineNavigationTitleDisplayMode()
        .navigationBarBackButtonHidden(viewModel.isSelectionMode)
        .navigationTitle(
            viewModel.isSelectionMode
                ? L10n.string("mine.download_queue.selected_count", viewModel.selectedWorkCount)
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
        .onChange(of: viewModel.groups.map(\.id)) {
            dismissIfGroupIsEmpty()
        }
        .onChange(of: viewModel.isLoading) { dismissIfGroupIsEmpty() }
        .onDisappear {
            viewModel.setSelectionMode(false)
        }
        .toolbar {
            if viewModel.isSelectionMode {
                ToolbarItem(placement: .cancellationAction) {
                    DownloadQueueSelectAllButton(
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
                    SelectionBottomToolbar(actions: DownloadQueueSelectionActions.cancel(viewModel: viewModel))
                }
            }
        }
        .toolbar(viewModel.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isSelectionMode && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(actions: DownloadQueueSelectionActions.cancel(viewModel: viewModel))
                    .selectionBottomToolbarCapsule()
            }
        }
        .overlay {
            if viewModel.isLoading && group == nil {
                ProgressView()
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.selectedWorkIDs)
        .downloadQueueFailureAlert(viewModel)
    }

    private func dismissIfGroupIsEmpty() {
        if group == nil, viewModel.loadFailure == nil, !viewModel.isLoading {
            dismiss()
        }
    }
}

extension View {
    fileprivate func downloadQueueFailureAlert(_ model: DownloadQueueViewModel, isActive: Bool = true) -> some View {
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

private struct DownloadQueueChapterRowView: View {
    let chapter: DownloadQueueChapterRow
    let runState: DownloadQueueRunState
    let isCommandRunning: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let toggleSelection: () -> Void
    let cancel: () -> Void
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

                Spacer(minLength: 8)

                Text(chapter.percentageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(dimming.secondaryColor)
                    .lineLimit(1)
            }

            DownloadQueueProgress(
                fraction: chapter.progressFraction,
                progressText: chapter.progressText,
                speedText: runState == .running && chapter.state == .running ? chapter.speedText : nil,
                failureText: chapter.failureStatusText,
                isDimmed: dimming.isDimmed
            )

            HStack {
                Label(statusTitle, systemImage: statusImage)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dimming.emphasis(chapter.state == .failed ? .red : appTheme.controlAccent))
                Spacer(minLength: 8)
            }
        }
        .downloadListRow(isSelected: isSelected, action: selectionAction)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button(role: .destructive, action: cancel) {
                    Label(L10n.string("mine.download_queue.cancel_download"), systemImage: "xmark.circle")
                }
                .disabled(isCommandRunning)
            }
        }
        .contextMenu {
            if !isSelecting {
                Button(role: .destructive, action: cancel) {
                    Label(L10n.string("mine.download_queue.cancel_download"), systemImage: "xmark.circle")
                }
                .disabled(isCommandRunning)
            }
        }
    }

    private var selectionAction: (() -> Void)? {
        guard isSelecting else { return nil }
        return { toggleSelection() }
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private var statusTitle: String {
        if chapter.state == .failed { return L10n.string("settings.download.state.failed") }
        if runState != .running { return L10n.string("settings.download.state.paused") }
        return L10n.string(
            chapter.state == .running
                ? "settings.download.state.running" : "settings.download.state.queued")
    }

    private var statusImage: String {
        if chapter.state == .failed { return "exclamationmark.circle" }
        if runState != .running { return "pause.circle" }
        return chapter.state == .running ? "arrow.down.circle" : "clock"
    }
}

private struct DownloadQueueProgress: View {
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

private struct DownloadQueueEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("mine.download_queue.empty_title"), systemImage: "arrow.down.circle")
        } description: {
            Text(L10n.string("mine.download_queue.empty_message"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
