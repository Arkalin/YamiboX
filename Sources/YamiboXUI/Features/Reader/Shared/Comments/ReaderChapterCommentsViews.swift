import SwiftUI
import YamiboXCore

#if os(iOS)
struct ReaderChapterCommentsContent: View {
    private static let loadNextColor = YamiboColors.Site.brownEmphasis
    static let refreshErrorRowID = "__refresh_error__"
    static let loadNextRowID = "__load_next__"
    private static let cardCornerRadius: CGFloat = 10

    let state: ReaderChapterCommentsState
    let isLoadingMore: Bool
    let loadMoreError: String?
    let refreshError: String?
    @Binding var scrollTarget: String?
    let retry: (ReaderChapterCommentTarget) -> Void
    let loadNext: () -> Void
    let openOriginalPost: (URL) -> Void
    var emptyTitle = L10n.string("reader.chapter_comments_empty")

    var body: some View {
        content
    }

    // The comment list is a hand-rolled inset-grouped ScrollView instead of a
    // List: `scrollPosition(id:)` (needed for drift-free controller scrolling)
    // only works on ScrollView + scrollTargetLayout.
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
        case let .failed(target, message):
            LoadFailureView(message: message, prominentRetry: true) {
                retry(target)
            }
            .padding()
        case let .loaded(target, page):
            if page.comments.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "text.bubble"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let refreshError {
                            refreshErrorCard(refreshError)
                                .id(Self.refreshErrorRowID)
                        }
                        ForEach(page.comments) { comment in
                            commentCardRow(comment, target: target, page: page)
                                .id(comment.id)
                        }
                        if page.nextView != nil {
                            loadNextButton
                                .padding(.top, 10)
                                .id(Self.loadNextRowID)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
                .scrollPosition(id: $scrollTarget, anchor: .top)
                .background(Color(.systemGroupedBackground))
            }
        }
    }

    private func refreshErrorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
            .padding(.bottom, 16)
    }

    private func commentCardRow(
        _ comment: ChapterComment,
        target: ReaderChapterCommentTarget,
        page: ChapterCommentsPage
    ) -> some View {
        let isFirst = comment.id == page.comments.first?.id
        let isLast = comment.id == page.comments.last?.id
        return ReaderChapterCommentRow(
            comment: comment,
            originalPostURL: comment.originalPostURL(threadID: target.threadID),
            openOriginalPost: openOriginalPost
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider()
                    .padding(.leading, 16)
            }
        }
        .clipShape(.rect(
            topLeadingRadius: isFirst ? Self.cardCornerRadius : 0,
            bottomLeadingRadius: isLast ? Self.cardCornerRadius : 0,
            bottomTrailingRadius: isLast ? Self.cardCornerRadius : 0,
            topTrailingRadius: isFirst ? Self.cardCornerRadius : 0,
            style: .continuous
        ))
    }

    private var loadNextButton: some View {
        Button(action: loadNext) {
            HStack {
                Spacer()
                if isLoadingMore {
                    ProgressView()
                        .tint(Self.loadNextColor)
                } else {
                    Text(loadMoreError ?? L10n.string("reader.chapter_comments_load_next"))
                        .font(.footnote.weight(.medium))
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(Self.loadNextColor)
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
    let refreshError: String?
    let loadInitial: (ReaderChapterCommentTarget?) async -> Void
    let refresh: (ReaderChapterCommentTarget?) async -> Void
    let loadNext: () async -> Void
    let peripheralInput: ReaderPeripheralInputManager?
    let emptyTitle: String

    private let forumDependencies: ForumDependencies
    private let appModel: YamiboAppModel
    private let discussionWorkTIDs: Set<String>

    @State private var threadOverlayItem: ForumThreadOverlayItem?
    @State private var scrollTarget: String?
    @State private var controlHandlerToken: UUID?

    init(
        target: ReaderChapterCommentTarget?,
        state: ReaderChapterCommentsState,
        isLoadingMore: Bool,
        loadMoreError: String?,
        refreshError: String?,
        loadInitial: @escaping (ReaderChapterCommentTarget?) async -> Void,
        refresh: @escaping (ReaderChapterCommentTarget?) async -> Void,
        loadNext: @escaping () async -> Void,
        forumDependencies: ForumDependencies,
        appModel: YamiboAppModel,
        discussionWorkTIDs: Set<String>,
        emptyTitle: String = L10n.string("reader.chapter_comments_empty")
    ) {
        self.target = target
        self.state = state
        self.isLoadingMore = isLoadingMore
        self.loadMoreError = loadMoreError
        self.refreshError = refreshError
        self.loadInitial = loadInitial
        self.refresh = refresh
        self.loadNext = loadNext
        self.peripheralInput = appModel.peripheralInput
        self.emptyTitle = emptyTitle
        self.forumDependencies = forumDependencies
        self.appModel = appModel
        self.discussionWorkTIDs = discussionWorkTIDs
    }

    var body: some View {
        NavigationStack {
            ReaderChapterCommentsContent(
                state: state,
                isLoadingMore: isLoadingMore,
                loadMoreError: loadMoreError,
                refreshError: refreshError,
                scrollTarget: $scrollTarget,
                retry: retry(_:),
                loadNext: loadNextPage,
                openOriginalPost: openOriginalPost(_:),
                emptyTitle: emptyTitle
            )
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
            await loadInitial(target)
        }
        .onAppear {
            guard let peripheralInput, controlHandlerToken == nil else { return }
            controlHandlerToken = peripheralInput.pushHandler { event in
                handleControlEvent(event)
            }
        }
        .onDisappear {
            peripheralInput?.removeHandler(controlHandlerToken)
            controlHandlerToken = nil
        }
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        // While the original-post cover is up, the comment list is fully
        // hidden; the cover is a touch-first surface, and close must not
        // tear down this sheet underneath it.
        guard threadOverlayItem == nil else { return }
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
        guard case let .loaded(_, page) = state, !page.comments.isEmpty,
              page.nextView != nil, !isLoadingMore else { return false }
        let ids = page.comments.map(\.id)
        return currentCommentIndex(ids: ids) >= ids.count - 1
    }

    private func scrollComments(_ direction: ReaderControlScrollDirection) {
        guard case let .loaded(_, page) = state, !page.comments.isEmpty else { return }
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
        Task { await loadInitial(target) }
    }

    private func loadNextPage() {
        Task { await loadNext() }
    }

    private func refreshCurrent() {
        Task { await refresh(target) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.authorName.isEmpty ? L10n.string("reader.comment_anonymous") : comment.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let metadata = comment.metadata {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                ReaderChapterCommentSourceBadge(source: comment.source)
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
            Text(comment.body)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

private struct ReaderChapterCommentSourceBadge: View {
    let source: ChapterCommentSource

    private var palette: (foreground: Color, border: Color) {
        switch source {
        case .postComment:
            (YamiboColors.Site.brownEmphasis, Color(red: 0.74, green: 0.52, blue: 0.38))
        case .ratingReason:
            (YamiboColors.Site.ratingReasonAccent, Color(red: 0.36, green: 0.65, blue: 0.55))
        case .reply:
            (YamiboColors.Site.replyAccent, Color(red: 0.48, green: 0.56, blue: 0.82))
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
