import SwiftUI
import YamiboXCore

struct ForumThreadReaderBodyView: View {
    @Namespace private var imageBrowserZoomNamespace
    @State private var imageBrowserRequest: ForumThreadImageBrowserRequest?
    @State private var ratingResultsRequest: ForumThreadRatingResultsRequest?
    @State private var pollVotersRequest: ForumThreadPollVotersRequest?
    @State private var visiblePostIDs: Set<String> = []

    let page: ForumThreadPage?
    let pageNavigation: ForumPageNavigation?
    let currentPage: Int
    let targetPostID: String?
    let restoredAnchorPostID: String?
    let onConsumeRestoredAnchor: () -> Void
    let onVisibleAnchorChange: (String?) -> Void
    let isLoading: Bool
    let errorMessage: String?
    let isFavorited: Bool
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let page {
                        ForEach(page.posts) { post in
                            let isFirstPost = currentPage == 1 && post.postID == page.posts.first?.postID
                            ForumThreadPostCard(
                                post: post,
                                isTarget: post.postID == targetPostID,
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
                                onURLTap: onURLTap
                            )
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
                        ForumContentLoadingView()
                    } else if let errorMessage {
                        ForumContentErrorView(message: errorMessage, retry: retry)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .refreshable {
                await refresh()
            }
            .topRefreshIndicator(isVisible: isLoading && page != nil)
            .task(id: scrollTaskIdentity(page: page, targetPostID: targetPostID, restoredAnchorPostID: restoredAnchorPostID)) {
                guard page != nil else { return }
                if let targetPostID {
                    guard page?.posts.contains(where: { $0.postID == targetPostID }) == true else {
                        return
                    }
                    // SwiftUI offers no layout-completion callback for freshly loaded
                    // LazyVStack content; scrolling immediately targets estimated row
                    // positions and lands off-target. The 150ms settle delay is an
                    // empirical workaround, not a synchronization mechanism.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(.snappy) {
                        proxy.scrollTo(targetPostID, anchor: .center)
                    }
                    return
                }
                guard let restoredAnchorPostID else { return }
                if page?.posts.contains(where: { $0.postID == restoredAnchorPostID }) == true {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(.snappy) {
                        proxy.scrollTo(restoredAnchorPostID, anchor: .center)
                    }
                }
                // Consume whether or not the anchor still exists on this
                // page — a pending-but-unmatchable anchor would otherwise
                // suppress anchor capture for the whole session. Deliberately
                // no immediate re-report here: LazyVStack's realize window
                // extends above the viewport, so "topmost realized post"
                // right after the restore scroll sits 1–N floors above the
                // restored anchor, and re-reporting it would drift the saved
                // anchor upward on every no-scroll visit. The consume seeds
                // the live anchor from the restored one; the next real
                // scroll's onAppear/onDisappear events take over from there.
                onConsumeRestoredAnchor()
            }
        }
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
        .safeAreaInset(edge: .bottom) {
            if let page {
                ForumThreadReaderActionBar(
                    thread: page.thread,
                    isFavorited: isFavorited,
                    onReply: {
                        onURLTap(YamiboRoute.threadReply(tid: page.thread.tid, page: currentPage).url)
                    },
                    onFavorite: toggleFavorite,
                    onFavoriteLongPress: presentFavoriteLocationPicker
                )
            }
        }
    }

    private func scrollTaskIdentity(page: ForumThreadPage?, targetPostID: String?, restoredAnchorPostID: String?) -> String {
        [
            targetPostID ?? "",
            restoredAnchorPostID ?? "",
            page?.posts.map(\.postID).joined(separator: ",") ?? ""
        ].joined(separator: "|")
    }

    /// Reports the topmost rendered post (in page order) as the floor-level
    /// reading anchor. `onAppear`/`onDisappear` track LazyVStack's realized
    /// window rather than exact pixel visibility — floor-level precision is
    /// the design target (browsing-history decision #6), not pixel offsets.
    private func reportVisibleAnchor() {
        guard let page else {
            onVisibleAnchorChange(nil)
            return
        }
        onVisibleAnchorChange(page.posts.first { visiblePostIDs.contains($0.postID) }?.postID)
    }

    private func openImageBrowser(_ imageID: String, _ url: URL, _ title: String?, _ refererURL: URL) {
        if let request = makeImageBrowserRequest(imageID, url, title, refererURL) {
            imageBrowserRequest = request
        } else {
            onURLTap(url)
        }
    }

    private func showRatingResults(postID: String) {
        ratingResultsRequest = ForumThreadRatingResultsRequest(postID: postID)
    }

    private func showPollVoters(optionID: String?) {
        pollVotersRequest = ForumThreadPollVotersRequest(optionID: optionID)
    }
}
