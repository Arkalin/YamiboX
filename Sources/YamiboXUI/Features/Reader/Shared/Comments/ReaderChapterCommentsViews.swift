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
    var openImage: ((ChapterComment, String) -> Void)? = nil
    var emptyTitle = L10n.string("reader.chapter_comments_empty")
    var discussions: [ChapterCommentDiscussion]? = nil
    var selectedDiscussion: ChapterCommentDiscussion? = nil
    var selectedConversation: ChapterCommentConversation? = nil
    var openReplies: ((ChapterCommentDiscussion) -> Void)? = nil
    var openConversation: ((String) -> Void)? = nil

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
            let groups = discussions ?? page.discussions
            if groups.isEmpty && selectedDiscussion == nil && selectedConversation == nil {
                VStack(spacing: 0) {
                    ContentUnavailableView(emptyTitle, systemImage: "text.bubble")
                    loadingFooter(page: page, target: target)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let root = selectedConversation?.root ?? selectedDiscussion?.root {
                            let replies = selectedConversation?.replies ?? selectedDiscussion?.replies ?? []
                            let separatesReplies = selectedConversation == nil && !replies.isEmpty
                            commentListRow(root, target: target, page: page, showsDivider: !separatesReplies)
                                .id(root.id)
                            if separatesReplies {
                                Color(.systemGray5)
                                    .frame(height: 8)
                                    .accessibilityHidden(true)
                            }
                            ForEach(replies) { reply in
                                commentListRow(reply.comment, target: target, page: page, replyingToName: reply.replyingToName,
                                               conversationRootID: reply.conversationRootID)
                                    .id(reply.id)
                            }
                        } else {
                            ForEach(groups) { discussion in
                                commentListRow(discussion.root, target: target, page: page, discussion: discussion)
                                    .id(discussion.id)
                            }
                        }
                        loadingFooter(page: page, target: target)
                            .id(Self.loadNextRowID)
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
        page: ChapterCommentsPage,
        discussion: ChapterCommentDiscussion? = nil,
        replyingToName: String? = nil,
        conversationRootID: String? = nil,
        showsDivider: Bool = true
    ) -> some View {
        let isLast = comment.id == page.comments.last?.id
        let replyTarget = ReaderChapterCommentComposeTarget.reply(comment, chapter: target)
        let replyAction: (() -> Void)? = if let replyTarget, let compose { { compose(replyTarget) } } else { nil }
        let navigationAction: ReaderChapterCommentNavigationAction? = if replyingToName != nil, let conversationRootID, let openConversation {
            .init(title: L10n.string("reader.comment_view_conversation"), identifier: "chapter-comment-conversation-\(comment.id)",
                  showsChevron: false, perform: { openConversation(conversationRootID) })
        } else if let discussion, !discussion.replies.isEmpty, let openReplies {
            .init(title: L10n.string(page.isComplete ? "reader.comment_replies_count" : "reader.comment_replies_loaded", discussion.replies.count),
                  identifier: "chapter-comment-replies-\(comment.id)", showsChevron: true, perform: { openReplies(discussion) })
        } else { nil }
        return VStack(alignment: .leading, spacing: 0) {
            ReaderChapterCommentRow(
                comment: comment,
                originalPostURL: comment.originalPostURL(threadID: target.threadID),
                openOriginalPost: openOriginalPost,
                onReply: replyAction,
                onImageTap: { blockID in openImage?(comment, blockID) },
                replyingToName: replyingToName,
                navigationAction: navigationAction
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chapter-comment-row-\(comment.id)")
        .overlay(alignment: .bottom) {
            if showsDivider && !isLast {
                Divider()
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func loadingFooter(page: ChapterCommentsPage, target: ReaderChapterCommentTarget) -> some View {
        if isLoadingMore {
            HStack {
                Spacer()
                ProgressView(L10n.string("common.loading"))
                    .tint(appTheme.controlAccent)
                Spacer()
            }
            .padding(.vertical, 12)
        } else if !page.isComplete {
            Button(L10n.string("common.retry")) {
                if page.needsInitialRetry == true { retry(target) } else { loadNext() }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("chapter-comments-retry-more")
        }
    }
}

private enum ReaderChapterCommentRoute: Hashable {
    case discussion(String)
    case conversation(discussionID: String, rootID: String)
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
    let cancelLoading: () -> Void
    private let composerActions: ReaderChapterCommentComposeActions?

    private let forumDependencies: ForumDependencies
    private let appModel: YamiboAppModel
    private let discussionWorkTIDs: Set<String>

    @State private var threadOverlayItem: ForumThreadOverlayItem?
    @State private var imageBrowserRequest: ForumThreadImageBrowserRequest?
    @State private var scrollTarget: String?
    @State private var replyScrollTarget: String?
    @State private var navigationPath: [ReaderChapterCommentRoute] = []
    @State private var conversationScrollTarget: String?
    @State private var controlHandlerToken: UUID?
    @State private var actionTask: Task<Void, Never>?
    @State private var composerTarget: ReaderChapterCommentComposeTarget?
    @State private var feedback: TransientFeedback?
    @State private var pendingSubmissionFeedback: TransientFeedback?
    @State private var refreshAnchor: String?
    @State private var replyRefreshAnchor: String?
    @State private var conversationRefreshAnchor: String?
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
        emptyTitle: String = L10n.string("reader.chapter_comments_empty"),
        cancelLoading: @escaping () -> Void = {},
        composerActions: ReaderChapterCommentComposeActions? = nil
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
        self.cancelLoading = cancelLoading
        self.composerActions = composerActions
        _filterModel = State(initialValue: ChapterCommentFilterModel(
            settingsStore: forumDependencies.settingsStore,
            sessionStore: forumDependencies.sessionStore,
            profileStore: forumDependencies.profileStore
        ))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            commentsScreen(discussion: nil)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
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
            .navigationDestination(for: ReaderChapterCommentRoute.self) { route in
                destination(route)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            ReaderToolbarIconButton(systemName: "arrow.clockwise", title: L10n.string("common.refresh"), action: refreshCurrent)
                        }
                    }
            }
        }
        .transientMessage(feedback) { feedback = nil }
        .sheet(item: $composerTarget, onDismiss: composerDismissed) { composeTarget in
            let accountGeneration = appModel.accountGeneration
            ReaderChapterCommentComposerSheet(
                model: ReaderChapterCommentComposerModel(
                    target: composeTarget,
                    actions: composerActions ?? ReaderChapterCommentComposeActions(dependencies: forumDependencies) { change in
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
        .fullScreenCover(item: $imageBrowserRequest) { request in
            ImageBrowserView(
                items: request.items,
                initialItemID: request.initialItemID,
                mode: request.items.count == 1 ? .single : .multiple,
                onDismiss: { imageBrowserRequest = nil }
            )
        }
        .task(id: target) {
            actionTask?.cancel()
            cancelLoading()
            navigationPath = []
            replyScrollTarget = nil
            conversationScrollTarget = nil
            let task = Task { await loadInitial(target) }
            actionTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .onChange(of: state, initial: true) { _, state in filterModel.update(state) }
        .onChange(of: filterModel.discussions) { _, _ in pruneCompletedNavigation() }
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
            pruneCompletedNavigation()
            let anchor = refreshAnchor ?? scrollTarget
            if filterModel.discussions.contains(where: { $0.id == anchor }) {
                scrollTarget = anchor
                refreshAnchor = nil
            } else if page.isComplete {
                scrollTarget = nil
                refreshAnchor = nil
            }
            if case let .discussion(id) = navigationPath.first {
                let group = filterModel.discussions.first { $0.id == id }
                if let group, let anchor = replyRefreshAnchor {
                    if group.id == anchor || group.replies.contains(where: { $0.id == anchor }) {
                        replyScrollTarget = anchor
                        replyRefreshAnchor = nil
                    } else if page.isComplete {
                        replyRefreshAnchor = nil
                    }
                }
            }
            if case let .conversation(discussionID, rootID) = navigationPath.last {
                let conversation = conversation(discussionID: discussionID, rootID: rootID)
                if let conversation, let anchor = conversationRefreshAnchor {
                    if conversation.id == anchor || conversation.replies.contains(where: { $0.id == anchor }) {
                        conversationScrollTarget = anchor
                        conversationRefreshAnchor = nil
                    } else if page.isComplete {
                        conversationRefreshAnchor = nil
                    }
                }
            }
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
            cancelLoading()
            peripheralInput?.removeHandler(controlHandlerToken)
            controlHandlerToken = nil
        }
    }

    @ViewBuilder
    private func destination(_ route: ReaderChapterCommentRoute) -> some View {
        switch route {
        case let .discussion(id):
            Group {
                if let discussion = filterModel.discussions.first(where: { $0.id == id }) {
                    commentsScreen(discussion: discussion)
                } else {
                    pendingSelection
                }
            }
            .navigationTitle(L10n.string("reader.comment_replies_title"))
        case let .conversation(discussionID, rootID):
            Group {
                if let conversation = conversation(discussionID: discussionID, rootID: rootID) {
                    commentsScreen(discussion: nil, conversation: conversation)
                } else {
                    pendingSelection
                }
            }
            .navigationTitle(L10n.string("reader.comment_conversation_title"))
        }
    }

    private func conversation(discussionID: String, rootID: String) -> ChapterCommentConversation? {
        filterModel.discussions.first { $0.id == discussionID }?.conversations.first { $0.id == rootID }
    }

    private func pruneCompletedNavigation() {
        guard case let .loaded(_, page) = filterModel.state, page.isComplete else { return }
        if case let .discussion(id) = navigationPath.first,
           !filterModel.discussions.contains(where: { $0.id == id }) {
            navigationPath = []
        }
        if case let .conversation(discussionID, rootID) = navigationPath.last,
           conversation(discussionID: discussionID, rootID: rootID) == nil {
            navigationPath.removeLast()
        }
    }

    private var pendingSelection: some View {
        VStack {
            if isLoadingMore {
                ProgressView()
            } else {
                Button(L10n.string("common.retry")) {
                    if case let .loaded(_, page) = state, page.needsInitialRetry != true { loadNextPage() }
                    else if let target { retry(target) }
                }
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .failureToast(message: loadMoreError ?? refreshError,
                      details: loadMoreError != nil ? loadMoreErrorDetails : refreshErrorDetails,
                      eventID: failureEventID, clear: clearFailure)
    }

    private func commentsScreen(discussion: ChapterCommentDiscussion?, conversation: ChapterCommentConversation? = nil) -> some View {
        ReaderChapterCommentsContent(
            state: filterModel.state, isLoadingMore: isLoadingMore,
            loadMoreError: loadMoreError, loadMoreErrorDetails: loadMoreErrorDetails,
            refreshError: refreshError, refreshErrorDetails: refreshErrorDetails,
            failureEventID: failureEventID, clearFailure: clearFailure,
            scrollTarget: conversation != nil ? $conversationScrollTarget : discussion == nil ? $scrollTarget : $replyScrollTarget,
            retry: retry(_:), loadNext: loadNextPage, openOriginalPost: openOriginalPost(_:),
            compose: { composerTarget = $0 }, openImage: openImage(_:blockID:),
            emptyTitle: filterModel.hasHiddenComments ? L10n.string("reader.chapter_comments_filtered_empty") : emptyTitle,
            discussions: filterModel.discussions, selectedDiscussion: discussion, selectedConversation: conversation,
            openReplies: { replyScrollTarget = nil; navigationPath.append(.discussion($0.id)) },
            openConversation: discussion.map { discussion in
                { rootID in
                    conversationScrollTarget = nil
                    navigationPath.append(.conversation(discussionID: discussion.id, rootID: rootID))
                }
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if conversation == nil, let target {
                let composeTarget = discussion.map { ReaderChapterCommentComposeTarget.reply($0.root, chapter: target) }
                    ?? ReaderChapterCommentComposeTarget.owner(target)
                if let composeTarget {
                    ReaderChapterCommentComposeBar { composerTarget = composeTarget }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleControlEvent(_ event: ReaderControlEvent) {
        // Presented content owns input; closing must not dismiss this sheet underneath it.
        guard threadOverlayItem == nil, composerTarget == nil, imageBrowserRequest == nil else { return }
        switch ReaderControlCommandResolver.commentsCommand(for: event) {
        case .close:
            if !navigationPath.isEmpty { navigationPath.removeLast() } else { dismiss() }
        case let .scroll(direction):
            scrollComments(direction)
        case nil:
            break
        }
    }

    private func currentCommentIndex(ids: [String]) -> Int {
        let activeTarget = activeScrollTarget.wrappedValue
        return if let activeTarget, let index = ids.firstIndex(of: activeTarget) {
            index
        } else if activeTarget == ReaderChapterCommentsContent.loadNextRowID {
            ids.count - 1
        } else {
            0
        }
    }

    private func scrollComments(_ direction: ReaderControlScrollDirection) {
        let ids: [String]
        switch navigationPath.last {
        case let .conversation(discussionID, rootID):
            guard let conversation = conversation(discussionID: discussionID, rootID: rootID) else { return }
            ids = [conversation.id] + conversation.replies.map(\.id)
        case let .discussion(id):
            guard let group = filterModel.discussions.first(where: { $0.id == id }) else { return }
            ids = [group.id] + group.replies.map(\.id)
        case nil:
            ids = filterModel.discussions.map(\.id)
        }
        guard !ids.isEmpty else { return }
        let currentIndex = currentCommentIndex(ids: ids)
        let stride = ReaderControlCommandResolver.commentsScrollStride
        let desiredIndex = direction == .down ? currentIndex + stride : currentIndex - stride
        let clampedIndex = min(max(desiredIndex, 0), ids.count - 1)
        withAnimation(.easeInOut(duration: 0.25)) {
            activeScrollTarget.wrappedValue = ids[clampedIndex]
        }
    }

    private var activeScrollTarget: Binding<String?> {
        switch navigationPath.last {
        case .conversation: $conversationScrollTarget
        case .discussion: $replyScrollTarget
        case nil: $scrollTarget
        }
    }

    private func retry(_ target: ReaderChapterCommentTarget) {
        actionTask?.cancel()
        cancelLoading()
        actionTask = Task { await refresh(target) }
    }

    private func loadNextPage() {
        guard !isLoadingMore else { return }
        actionTask?.cancel()
        cancelLoading()
        actionTask = Task { await loadNext() }
    }

    private func refreshCurrent() {
        refreshAnchor = scrollTarget
        replyRefreshAnchor = replyScrollTarget
        conversationRefreshAnchor = conversationScrollTarget
        actionTask?.cancel()
        cancelLoading()
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

    private func openImage(_ comment: ChapterComment, blockID: String) {
        guard let target else { return }
        imageBrowserRequest = ReaderChapterCommentImageGallery.request(comment: comment, target: target, selectedBlockID: blockID)
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

private struct ReaderChapterCommentNavigationAction {
    let title: String
    let identifier: String
    let showsChevron: Bool
    let perform: () -> Void
}

private struct ReaderChapterCommentRow: View {
    let comment: ChapterComment
    let originalPostURL: URL?
    let openOriginalPost: (URL) -> Void
    let onReply: (() -> Void)?
    let onImageTap: (String) -> Void
    var replyingToName: String? = nil
    var navigationAction: ReaderChapterCommentNavigationAction? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForumAvatarView(url: comment.authorAvatarURL, size: 28, placeholderFont: .system(size: 22))
                    .accessibilityHidden(true)
                Text(comment.authorName.isEmpty ? L10n.string("reader.comment_anonymous") : comment.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if comment.isThreadAuthor == true {
                    Text(L10n.string("reader.comment_author"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
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
                    .accessibilityIdentifier("chapter-comment-original-\(comment.id)")
                }
            }
            if comment.isFiltered == true {
                Text(L10n.string("reader.comment_filtered"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comment.quoteBlocks ?? []) { block in
                    if case let .quote(blocks) = block.kind {
                        ReaderChapterCommentBody(
                            text: "", blocks: nil, refererURL: originalPostURL ?? YamiboDomain.baseURL,
                            contentBlocks: blocks, imageIdentifierPrefix: "chapter-comment-image-\(comment.id)", onImageTap: onImageTap
                        )
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                    }
                }
                ReaderChapterCommentBody(
                    text: comment.body,
                    blocks: comment.bodyBlocks,
                    refererURL: originalPostURL ?? YamiboDomain.baseURL,
                    contentBlocks: comment.contentBlocks,
                    imageIdentifierPrefix: "chapter-comment-image-\(comment.id)",
                    onImageTap: onImageTap,
                    replyingToName: replyingToName
                )
                .accessibilityIdentifier("chapter-comment-body-\(comment.id)")
            }
            if comment.metadata != nil || onReply != nil || navigationAction != nil {
                ReaderChapterCommentFooter(
                    metadata: comment.metadata,
                    replyIdentifier: comment.postID ?? comment.id,
                    onReply: onReply,
                    navigationAction: navigationAction
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ReaderChapterCommentFooter: View {
    @Environment(\.appTheme) private var theme

    let metadata: String?
    let replyIdentifier: String
    let onReply: (() -> Void)?
    let navigationAction: ReaderChapterCommentNavigationAction?

    var body: some View {
        HStack(alignment: navigationAction == nil ? .center : .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let metadata {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let navigationAction {
                    Button(action: navigationAction.perform) {
                        HStack(spacing: 4) {
                            Text(navigationAction.title)
                                .font(.footnote)
                            if navigationAction.showsChevron {
                                Image(systemName: "chevron.forward")
                                    .font(.caption2.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .expandedHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navigationAction.showsChevron ? theme.controlAccent : Color.secondary)
                    .accessibilityLabel(navigationAction.title)
                    .accessibilityIdentifier(navigationAction.identifier)
                }
            }
            Spacer(minLength: 0)
            if let onReply {
                Button(action: onReply) {
                    Text(L10n.string("reader.comments"))
                        .font(.footnote)
                        .fixedSize()
                        .frame(minWidth: 44)
                        .expandedHitTarget()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("reader.comments"))
                .accessibilityIdentifier("chapter-comment-reply-\(replyIdentifier)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var contentBlocks: [ForumThreadContentBlock]? = nil
    var imageIdentifierPrefix = "chapter-comment-image"
    var onImageTap: (String) -> Void = { _ in }
    var replyingToName: String? = nil

    var body: some View {
        if let contentBlocks, !contentBlocks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let first = contentBlocks.first, case .image = first.kind, let replyingToName {
                    Text(L10n.string("reader.comment_reply_prefix", replyingToName)).font(.body)
                }
                ForEach(contentBlocks) { block in
                    switch block.kind {
                    case let .text(text):
                        ReaderChapterCommentText(attributedText: prefixed(ForumThreadTextBlockFormatter(block: text).attributedText, enabled: block.id == contentBlocks.first?.id), refererURL: refererURL)
                    case .image:
                        Button { onImageTap(block.id) } label: {
                            Label(L10n.string("reader.comment_view_image"), systemImage: "photo")
                                .font(.body)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("\(imageIdentifierPrefix)-\(block.id)")
                    default:
                        EmptyView()
                    }
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            ReaderChapterCommentText(attributedText: attributedText, refererURL: refererURL)
        }
    }

    var attributedText: AttributedString {
        guard let blocks, !blocks.isEmpty else { return prefixed(AttributedString(text)) }
        return prefixed(blocks.reduce(into: AttributedString()) { result, block in
            if !result.characters.isEmpty {
                result.append(AttributedString("\n"))
            }
            result.append(ForumThreadTextBlockFormatter(block: block).attributedText)
        })
    }

    private func prefixed(_ text: AttributedString, enabled: Bool = true) -> AttributedString {
        guard enabled, let replyingToName else { return text }
        return AttributedString(L10n.string("reader.comment_reply_prefix", replyingToName)) + text
    }
}

private struct ReaderChapterCommentText: View {
    let attributedText: AttributedString
    let refererURL: URL

    var body: some View {
        ForumThreadInlineTextView(attributedText: attributedText, refererURL: refererURL)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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
