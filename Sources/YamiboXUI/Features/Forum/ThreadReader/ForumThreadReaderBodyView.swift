import SwiftUI
import YamiboXCore

struct ForumThreadReaderBodyView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.forumBlacklist) private var blacklist
    @ScaledMetric(relativeTo: .body) private var readableWidth: CGFloat = 700
    @Namespace private var imageBrowserZoomNamespace
    @State private var imageBrowserRequest: ForumThreadImageBrowserRequest?
    @State private var ratingResultsRequest: ForumThreadRatingResultsRequest?
    @State private var pollVotersRequest: ForumThreadPollVotersRequest?
    @State private var visiblePostIDs: Set<String> = []
    @State private var highlightedPostID: String?

    let page: ForumThreadPage?
    let pageNavigation: ForumPageNavigation?
    let currentPage: Int
    let targetPostID: String?
    let restoredAnchorPostID: String?
    let onConsumeRestoredAnchor: () -> Void
    let onVisibleAnchorChange: (String?) -> Void
    let isLoading: Bool
    let errorMessage: String?
    var errorDetails: LoadFailureDetails? = nil
    let isFavorited: Bool
    let isFavoriteWorking: Bool
    /// 倒序浏览: page 1 opens on the newest replies, so no post on it carries
    /// the thread's title and counters.
    let isReverseOrder: Bool
    let refresh: () async -> Void
    let retry: () -> Void
    let goToPage: (Int) -> Void
    let toggleFavorite: () -> Void
    let presentFavoriteLocationPicker: () -> Void
    let makeImageBrowserRequest: (String, URL, String?, URL) -> ForumThreadImageBrowserRequest?
    let imageBrowserCoverActionsProvider: ImageBrowserCoverActionsProvider
    let loadRatingResults: (String) async throws -> ForumThreadRatingResultsPage
    let loadRateOptions: (String) async throws -> ForumThreadRateOptionsPage
    let loadPollVoters: (String?, Int) async throws -> ForumThreadPollVotersPage
    let votePoll: ([String]) async throws -> String
    let ratePost: (String, Int, String, Bool) async throws -> String
    let commentPost: (String, String) async throws -> String
    let onUserTap: (String, String?) -> Void
    let onURLTap: (URL) -> Void
    let onAttachmentTap: (ForumThreadAttachmentBlock) -> Void
    var onReaderModeSwitch: ((YamiboThreadReaderOverride) -> Void)? = nil
    var isSwitchingReaderMode = false
    var recommendedReaderKind: YamiboThreadKind = .unknown

    var body: some View {
        contentWithSheets
            .environment(\.imageBrowserZoomNamespace, imageBrowserZoomNamespace)
            .fullScreenCover(item: $imageBrowserRequest) { request in
                ImageBrowserView(
                    items: request.items,
                    initialItemID: request.initialItemID,
                    mode: .multiple,
                    presentation: .zoom(imageBrowserZoomNamespace),
                    coverActionsProvider: imageBrowserCoverActionsProvider,
                    onDismiss: {
                        imageBrowserRequest = nil
                    }
                )
            }
            .onChange(of: blacklist?.blockedUIDs) { _, _ in
                imageBrowserRequest = nil
                reportVisibleAnchor()
            }
            .onChange(of: blacklist?.replyDisplay) { _, _ in reportVisibleAnchor() }
    }

    private var contentWithSheets: some View {
        content
            .sheet(item: $ratingResultsRequest) { request in
                ForumThreadRatingResultsSheet(
                    request: request,
                    load: loadRatingResults,
                    onUserTap: onUserTap
                )
            }
            .sheet(item: $pollVotersRequest) { request in
                ForumThreadPollVotersSheet(
                    request: request,
                    load: loadPollVoters,
                    onUserTap: onUserTap
                )
            }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let page {
                    if let hiddenAnchorPost {
                        ForumBlockedContentView(floor: hiddenAnchorPost.floorText)
                    } else if !page.posts.isEmpty && renderedPosts.isEmpty {
                        ForumBlacklistEmptyView()
                    }
                    ForEach(renderedPosts) { post in
                        let isFirstPost = currentPage == 1
                            && !isReverseOrder
                            && post.postID == page.posts.first?.postID
                        Group {
                            if blacklist?.contains(post.author.uid) == true {
                                ForumBlockedContentView(floor: post.floorText)
                            } else {
                                ForumThreadPostCard(
                                    post: post,
                                    isTarget: post.postID == highlightedPostID,
                                    threadTitle: isFirstPost ? page.title : nil,
                                    totalViews: isFirstPost ? page.totalViews : nil,
                                    totalReplies: isFirstPost ? page.totalReplies : nil,
                                    refererURL: YamiboRoute.threadByID(
                                        tid: page.thread.tid,
                                        page: currentPage,
                                        authorID: nil,
                                        reverse: false
                                    ).url,
                                    threadID: page.thread.tid,
                                    currentPage: currentPage,
                                    onUserTap: onUserTap,
                                    onImageTap: openImageBrowser,
                                    onShowRatingResults: showRatingResults,
                                    onShowPollVoters: showPollVoters,
                                    onVotePoll: votePoll,
                                    onLoadRateOptions: loadRateOptions,
                                    onRatePost: ratePost,
                                    onCommentPost: commentPost,
                                    onURLTap: onURLTap,
                                    onAttachmentTap: onAttachmentTap
                                )
                            }
                        }
                        .id(post.postID)
                        .onAppear {
                            visiblePostIDs.insert(post.postID)
                            reportVisibleAnchor()
                        }
                        .onDisappear {
                            visiblePostIDs.remove(post.postID)
                            reportVisibleAnchor()
                        }
                    }

                    ForumPageNavigationBar(
                        navigation: pageNavigation,
                        currentPage: currentPage,
                        goToPage: goToPage,
                        hidesOnSinglePage: true
                    )
                } else if isLoading {
                    ContentLoadingView()
                } else if let errorMessage {
                    ContentErrorView(message: errorMessage, details: errorDetails, retry: retry)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: readableWidth + 32)
            .frame(maxWidth: .infinity)
        }
        .id(currentPage)
        .refreshableWithTopIndicator(isRefreshing: isLoading && page != nil) {
            await refresh()
        }
        .modifier(ForumThreadAnchorScrollModifier(
            postIDs: page.map { _ in renderedPosts.map(\.postID) }, targetPostID: targetPostID,
            restoredAnchorPostID: restoredAnchorPostID,
            highlightedPostID: $highlightedPostID,
            onConsumeRestoredAnchor: onConsumeRestoredAnchor
        ))
        .forumPageBackground()
        .tint(theme.accentText)
        .safeAreaInset(edge: .bottom) {
            if let page {
                ForumThreadReaderActionBar(
                    isFavorited: isFavorited,
                    isFavoriteWorking: isFavoriteWorking,
                    onReply: {
                        onURLTap(YamiboRoute.threadReply(tid: page.thread.tid, page: currentPage).url)
                    },
                    onFavorite: toggleFavorite,
                    onFavoriteLongPress: presentFavoriteLocationPicker,
                    onReaderModeSwitch: onReaderModeSwitch,
                    isSwitchingReaderMode: isSwitchingReaderMode || isLoading,
                    recommendedReaderKind: recommendedReaderKind
                )
            }
        }
    }

    /// Reports the topmost rendered post (in page order) as the floor-level
    /// reading anchor. `onAppear`/`onDisappear` track LazyVStack's realized
    /// window rather than exact pixel visibility — floor-level precision is
    /// the design target (browsing-history decision #6), not pixel offsets.
    private func reportVisibleAnchor() {
        guard page != nil else {
            onVisibleAnchorChange(nil)
            return
        }
        onVisibleAnchorChange(renderedPosts.first { visiblePostIDs.contains($0.postID) }?.postID)
    }

    private var renderedPosts: [ForumThreadPost] {
        guard blacklist?.replyDisplay == .hidden else { return page?.posts ?? [] }
        return (page?.posts ?? []).filter { blacklist?.contains($0.author.uid) != true }
    }

    private var hiddenAnchorPost: ForumThreadPost? {
        guard blacklist?.replyDisplay == .hidden, let anchor = targetPostID ?? restoredAnchorPostID else { return nil }
        return page?.posts.first { $0.postID == anchor && blacklist?.contains($0.author.uid) == true }
    }

    private func openImageBrowser(_ imageID: String, _ url: URL, _ title: String?, _ refererURL: URL) {
        if let request = makeImageBrowserRequest(imageID, url, title, refererURL) {
            imageBrowserRequest = request
        }
    }

    private func showRatingResults(postID: String) {
        ratingResultsRequest = ForumThreadRatingResultsRequest(postID: postID)
    }

    private func showPollVoters(optionID: String?) {
        pollVotersRequest = ForumThreadPollVotersRequest(optionID: optionID)
    }
}
