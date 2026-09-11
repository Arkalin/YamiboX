import SwiftUI
import YamiboXCore

#if os(iOS)
private enum ChapterCommentSourcePalette {
    static let action = Color(light: 0x4E2A1B, dark: 0xD6A083)
    static let rating = Color(light: 0x26705C, dark: 0x5FC9A8)
    static let reply = Color(light: 0x475CAD, dark: 0x8FA0E0)
    static let actionBorder = Color(red: 0.74, green: 0.52, blue: 0.38)
    static let ratingBorder = Color(red: 0.36, green: 0.65, blue: 0.55)
    static let replyBorder = Color(red: 0.48, green: 0.56, blue: 0.82)
}

struct ReaderChapterCommentsContent: View {
    static let loadNextRowID = "__load_next__"

    @Environment(\.appTheme) private var appTheme

    let state: ReaderChapterCommentsState
    let isLoadingMore: Bool
    let loadMoreError: String?
    var loadMoreErrorDetails: LoadFailureDetails? = nil
    let refreshError: String?
    var refreshErrorDetails: LoadFailureDetails? = nil
    var failureEventID: UUID? = nil
    var clearFailure: @MainActor () -> Void = {}
    @Binding var scrollTarget: String?
    let retry: (ReaderChapterCommentTarget) -> Void
    let loadNext: () -> Void
    let openOriginalPost: (URL) -> Void
    var compose: ((ReaderChapterCommentComposeTarget) -> Void)? = nil
    var emptyTitle = L10n.string("reader.chapter_comments_empty")

    var body: some View {
        content
            .background(Color(.systemBackground).ignoresSafeArea())
            .failureToast(message: loadMoreError ?? refreshError,
                          details: loadMoreError != nil ? loadMoreErrorDetails : refreshErrorDetails,
                          eventID: failureEventID, clear: clearFailure)
    }

    // Keep this as a ScrollView rather than a List: `scrollPosition(id:)`
    // (needed for drift-free controller scrolling) only works here with
    // `scrollTargetLayout`.
    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.string("common.loading"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unsupported:
            ContentUnavailableView(
                L10n.string("reader.chapter_comments_unsupported"),
                systemImage: "text.bubble"
            )
        case let .failed(target, message, details):
            LoadFailureView(message: message, details: details, prominentRetry: true) {
                retry(target)
            }
            .padding()
        case let .loaded(target, page):
            if page.comments.isEmpty {
                VStack(spacing: 0) {
                    ContentUnavailableView(emptyTitle, systemImage: "text.bubble")
                    if page.nextView != nil { loadNextButton }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(page.comments) { comment in
                            commentListRow(comment, target: target, page: page)
                                .id(comment.id)
                        }
                        if page.nextView != nil {
                            loadNextButton
                                .id(Self.loadNextRowID)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $scrollTarget, anchor: .top)
            }
        }
    }

    private func commentListRow(
        _ comment: ChapterComment,
        target: ReaderChapterCommentTarget,
        page: ChapterCommentsPage
    ) -> some View {
        let isLast = comment.id == page.comments.last?.id
        let replyTarget = ReaderChapterCommentComposeTarget.reply(comment, chapter: target)
        let replyAction: (() -> Void)? = if let replyTarget, let compose { { compose(replyTarget) } } else { nil }
        return ReaderChapterCommentRow(
            comment: comment,
            originalPostURL: comment.originalPostURL(threadID: target.threadID),
            openOriginalPost: openOriginalPost,
            onReply: replyAction
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider()
                    .padding(.leading, 16)
            }
        }
    }

    private var loadNextButton: some View {
        Button(action: loadNext) {
            HStack {
                Spacer()
                if isLoadingMore {
                    ProgressView()
                        .tint(appTheme.controlAccent)
                } else {
                    Text(L10n.string("reader.chapter_comments_load_next"))
                        .font(.footnote.weight(.medium))
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(appTheme.controlAccent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMore)
    }
}

struct ReaderChapterCommentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let target: ReaderChapterCommentTarget?
    let state: ReaderChapterCommentsState
    let isLoadingMore: Bool
    let loadMoreError: String?
    var loadMoreErrorDetails: LoadFailureDetails? = nil
    let refreshError: String?
    let refreshErrorDetails: LoadFailureDetails?
    let failureEventID: UUID?
    let clearFailure: @MainActor () -> Void
    let loadInitial: (ReaderChapterCommentTarget?) async -> Void
    let refresh: (ReaderChapterCommentTarget?) async -> Void
    let loadNext: () async -> Void
    let peripheralInput: ReaderPeripheralInputManager?
    let emptyTitle: String
    let isNovel: Bool
    let hasLaterChapter: Bool

    private let forumDependencies: ForumDependencies
    private let appModel: YamiboAppModel
    private let discussionWorkTIDs: Set<String>

    @State private var threadOverlayItem: ForumThreadOverlayItem?
    @State private var scrollTarget: String?
    @State private var controlHandlerToken: UUID?
    @State private var actionTask: Task<Void, Never>?
    @State private var composerTarget: ReaderChapterCommentComposeTarget?
    @State private var feedback: TransientFeedback?
    @State private var pendingSubmissionFeedback: TransientFeedback?
    @State private var refreshAnchor: String?
    @State private var filterModel: ChapterCommentFilterModel

    init(
        target: ReaderChapterCommentTarget?,
        state: ReaderChapterCommentsState,
        isLoadingMore: Bool,
        loadMoreError: String?,
        loadMoreErrorDetails: LoadFailureDetails? = nil,
        refreshError: String?,
        refreshErrorDetails: LoadFailureDetails? = nil,
        failureEventID: UUID? = nil,
        clearFailure: @escaping @MainActor () -> Void = {},
        loadInitial: @escaping (ReaderChapterCommentTarget?) async -> Void,
        refresh: @escaping (ReaderChapterCommentTarget?) async -> Void,
        loadNext: @escaping () async -> Void,
        forumDependencies: ForumDependencies,
        appModel: YamiboAppModel,
        discussionWorkTIDs: Set<String>,
        isNovel: Bool = false,
        hasLaterChapter: Bool = false,
        emptyTitle: String = L10n.string("reader.chapter_comments_empty")
    ) {
        self.target = target
        self.state = state
        self.isLoadingMore = isLoadingMore
        self.loadMoreError = loadMoreError
        self.loadMoreErrorDetails = loadMoreErrorDetails
        self.refreshError = refreshError
        self.refreshErrorDetails = refreshErrorDetails
        self.failureEventID = failureEventID
        self.clearFailure = clearFailure
        self.loadInitial = loadInitial
        self.refresh = refresh
        self.loadNext = loadNext
        self.peripheralInput = appModel.peripheralInput
        self.emptyTitle = emptyTitle
        self.forumDependencies = forumDependencies
        self.appModel = appModel
        self.discussionWorkTIDs = discussionWorkTIDs
        self.isNovel = isNovel
        self.hasLaterChapter = hasLaterChapter
        _filterModel = State(initialValue: ChapterCommentFilterModel(
            settingsStore: forumDependencies.settingsStore,
            sessionStore: forumDependencies.sessionStore,
            profileStore: forumDependencies.profileStore
        ))
    }

    var body: some View {
        NavigationStack {
            ReaderChapterCommentsContent(
                state: filterModel.state,
                isLoadingMore: isLoadingMore,
                loadMoreError: loadMoreError,
                loadMoreErrorDetails: loadMoreErrorDetails,
                refreshError: refreshError,
                refreshErrorDetails: refreshErrorDetails,
                failureEventID: failureEventID,
                clearFailure: clearFailure,
                scrollTarget: $scrollTarget,
                retry: retry(_:),
                loadNext: loadNextPage,
                openOriginalPost: openOriginalPost(_:),
                compose: { composerTarget = $0 },
                emptyTitle: filterModel.hasHiddenComments ? L10n.string("reader.chapter_comments_filtered_empty") : emptyTitle
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let target, let owner = ReaderChapterCommentComposeTarget.owner(target) {
                    ReaderChapterCommentComposeBar { composerTarget = owner }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ReaderChapterCommentsToolbarTitle(target: target)
                }
                ToolbarItem(placement: .topBarLeading) {
                    ReaderToolbarIconButton(
                        systemName: "xmark",
                        title: L10n.string("common.done"),
                        action: { dismiss() }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ReaderToolbarIconButton(
                        systemName: "arrow.clockwise",
                        title: L10n.string("common.refresh"),
                        action: refreshCurrent
                    )
                    .disabled(target == nil)
                }
            }
        }
        .transientMessage(feedback) { feedback = nil }
        .sheet(item: $composerTarget, onDismiss: composerDismissed) { composeTarget in
            let accountGeneration = appModel.accountGeneration
            ReaderChapterCommentComposerSheet(
                model: ReaderChapterCommentComposerModel(
                    target: composeTarget,
                    actions: ReaderChapterCommentComposeActions(dependencies: forumDependencies) { change in
                        guard accountGeneration == appModel.accountGeneration else { return }
                        appModel.forumContentRefresh.record(change)
                    }
                ),
                replyPlacement: ReaderChapterReplyPlacement.resolve(target: composeTarget.chapter, hasLaterChapter: hasLaterChapter, state: state),
                isNovel: isNovel,
                onSubmitted: { pendingSubmissionFeedback = $0 }
            ) { url in
                ReaderChapterCommentComposerDestination(url: url, dependencies: forumDependencies,
                                                        appModel: appModel, discussionWorkTIDs: discussionWorkTIDs)
            }
        }
        .fullScreenCover(item: $threadOverlayItem) { item in
            ForumThreadOverlayScreen(
                item: item,
                dependencies: forumDependencies,
                appModel: appModel,
                rootIsDiscussionView: true,
                discussionWorkTIDs: discussionWorkTIDs
            )
        }
        .task(id: target) {
            actionTask?.cancel()
            await loadInitial(target)
        }
        .onChange(of: state, initial: true) { _, state in filterModel.update(state) }
        .task {
            let changes = forumDependencies.settingsStore.changes()
            filterModel.refresh()
            for await _ in changes { filterModel.refresh() }
        }
        .task {
            let changes = forumDependencies.sessionStore.changes()
            filterModel.refresh()
            for await _ in changes { filterModel.refresh() }
        }
        .task {
            let changes = forumDependencies.profileStore.changes()
            filterModel.refresh()
            for await _ in changes { filterModel.refresh() }
        }
        .onChange(of: filterModel.state) { _, state in
            guard case let .loaded(_, page) = state else { return }
            let anchor = refreshAnchor ?? scrollTarget
            scrollTarget = page.comments.contains { $0.id == anchor } ? anchor : nil
            self.refreshAnchor = nil
        }
        .onAppear {
            guard let peripheralInput, controlHandlerToken == nil else { return }
            controlHandlerToken = peripheralInput.pushHandler { event in
                handleControlEvent(event)
            }
        }
        .onDisappear {
            filterModel.cancel()
            actionTask?.cancel()
            actionTask = nil
            peripheralInput?.removeHandler(controlHandlerToken)
            controlHandlerToken = nil
        }
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        // While the original-post cover is up, the comment list is fully
        // hidden; the cover is a touch-first surface, and close must not
        // tear down this sheet underneath it.
        guard threadOverlayItem == nil, composerTarget == nil else { return }
        // The next-page bound action is a dead no-op everywhere else in this
        // sheet (dpad owns scrolling); only once already at the last loaded
        // comment does it act as "load next page", mirroring the
        // scroll-to-edge-then-cross feel of vertical-mode chapter boundaries.
        if event == .bound(.nextPage), isAtCommentsBottomWithMorePages {
            loadNextPage()
            return
        }
        switch ReaderControlCommandResolver.commentsCommand(for: event) {
        case .close:
            dismiss()
        case let .scroll(direction):
            scrollComments(direction)
        case nil:
            break
        }
    }

    private func currentCommentIndex(ids: [String]) -> Int {
        if let scrollTarget, let index = ids.firstIndex(of: scrollTarget) {
            index
        } else if scrollTarget == ReaderChapterCommentsContent.loadNextRowID {
            ids.count - 1
        } else {
            0
        }
    }

    private var isAtCommentsBottomWithMorePages: Bool {
        guard case let .loaded(_, page) = filterModel.state,
              page.nextView != nil, !isLoadingMore else { return false }
        let ids = page.comments.map(\.id)
        return currentCommentIndex(ids: ids) >= ids.count - 1
    }

    private func scrollComments(_ direction: ReaderControlScrollDirection) {
        guard case let .loaded(_, page) = filterModel.state else { return }
        guard !page.comments.isEmpty else {
            if direction == .down, page.nextView != nil { loadNextPage() }
            return
        }
        let ids = page.comments.map(\.id)
        let currentIndex = currentCommentIndex(ids: ids)
        let stride = ReaderControlCommandResolver.commentsScrollStride
        let desiredIndex = direction == .down ? currentIndex + stride : currentIndex - stride
        let clampedIndex = min(max(desiredIndex, 0), ids.count - 1)
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollTarget = ids[clampedIndex]
        }
        // Reaching the tail with more pages available loads the next one so
        // a controller user never has to touch the on-screen button.
        if direction == .down, desiredIndex >= ids.count - 1, page.nextView != nil, !isLoadingMore {
            loadNextPage()
        }
    }

    private func retry(_ target: ReaderChapterCommentTarget) {
        actionTask?.cancel()
        actionTask = Task { await loadInitial(target) }
    }

    private func loadNextPage() {
        guard !isLoadingMore else { return }
        actionTask?.cancel()
        actionTask = Task { await loadNext() }
    }

    private func refreshCurrent() {
        refreshAnchor = scrollTarget
        actionTask?.cancel()
        actionTask = Task { await refresh(target) }
    }

    private func composerDismissed() {
        guard let pendingSubmissionFeedback else { return }
        self.pendingSubmissionFeedback = nil
        feedback = pendingSubmissionFeedback
        refreshCurrent()
    }

    /// 查看原帖 opens the original post as a full-screen cover above this
    /// sheet instead of tearing down the reader underneath: closing the cover
    /// returns to the comment list, closing the sheet returns to reading.
    /// The cover root hardcodes `isDiscussionView: true`, keeping parity with
    /// the old `.readerDiscussion`-sourced jump — this companion view of the
    /// work must not write its own browsing-history row (browsing-history
    /// decision #14).
    private func openOriginalPost(_ url: URL) {
        threadOverlayItem = ForumThreadOverlayItem(url: url, title: target?.title)
    }
}

struct ReaderChapterCommentsToolbarTitle: View {
    let target: ReaderChapterCommentTarget?

    var body: some View {
        VStack(spacing: 1) {
            Text(L10n.string("reader.chapter_comments"))
                .font(.headline)
            if let title = target?.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ReaderChapterCommentRow: View {
    let comment: ChapterComment
    let originalPostURL: URL?
    let openOriginalPost: (URL) -> Void
    let onReply: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.authorName.isEmpty ? L10n.string("reader.comment_anonymous") : comment.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ReaderChapterCommentSourceBadge(source: comment.source)
                if let onReply {
                    Button(action: onReply) {
                        Image(systemName: "arrowshape.turn.up.left")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string("forum.thread.reply"))
                    .accessibilityIdentifier("chapter-comment-reply-\(comment.postID ?? comment.id)")
                }
                if let originalPostURL {
                    Button {
                        openOriginalPost(originalPostURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .expandedHitTarget()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string("reader.open_original_post"))
                }
            }
            if let metadata = comment.metadata {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ReaderChapterCommentBody(
                text: comment.body,
                blocks: comment.bodyBlocks,
                refererURL: originalPostURL ?? YamiboDomain.baseURL
            )
        }
        .padding(.vertical, 4)
    }
}

struct ReaderChapterCommentComposeBar: View {
    @Environment(\.appTheme) private var theme
    let compose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: compose) {
                Label(L10n.string("reader.comment_composer.write"), systemImage: "square.and.pencil")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.controlAccent)
            .padding(.vertical, 6)
            .accessibilityIdentifier("chapter-comment-compose")
        }
        .background(.regularMaterial)
    }
}

struct ReaderChapterCommentBody: View {
    let text: String
    let blocks: [ForumThreadTextBlock]?
    let refererURL: URL

    var body: some View {
        ForumThreadInlineTextView(attributedText: attributedText, refererURL: refererURL)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    var attributedText: AttributedString {
        guard let blocks, !blocks.isEmpty else { return AttributedString(text) }
        return blocks.reduce(into: AttributedString()) { result, block in
            if !result.characters.isEmpty {
                result.append(AttributedString("\n"))
            }
            result.append(ForumThreadTextBlockFormatter(block: block).attributedText)
        }
    }
}

private struct ReaderChapterCommentSourceBadge: View {
    let source: ChapterCommentSource

    private var palette: (foreground: Color, border: Color) {
        switch source {
        case .postComment:
            (ChapterCommentSourcePalette.action, ChapterCommentSourcePalette.actionBorder)
        case .ratingReason:
            (ChapterCommentSourcePalette.rating, ChapterCommentSourcePalette.ratingBorder)
        case .reply:
            (ChapterCommentSourcePalette.reply, ChapterCommentSourcePalette.replyBorder)
        }
    }

    var body: some View {
        Text(source.displayLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
            .accessibilityLabel(source.displayLabel)
    }
}
#endif
