import Foundation

public actor ReaderChapterCommentsRepository {
    private let client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    public func loadChapterComments(for target: ReaderChapterCommentTarget) async throws -> ChapterCommentsPage {
        let html = try await client.fetchThreadById(
            tid: target.threadID,
            authorID: target.authorID,
            page: target.view
        )
        var page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        if let fullRatingsURL = try ChapterCommentsHTMLParser.fullRatingReasonsURL(html: html, target: target) {
            let fullRatingsHTML: String?
            do {
                fullRatingsHTML = try await client.fetchHTML(url: fullRatingsURL)
            } catch {
                YamiboLog.forum.warning("loadChapterComments: failed to fetch full rating-reasons page; falling back to truncated preview ratings: \(error)")
                fullRatingsHTML = nil
            }
            if let fullRatingsHTML {
                let fullRatings = try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(
                    html: fullRatingsHTML,
                    target: target
                )
                if !fullRatings.isEmpty {
                    page.comments = Self.replacingPreviewRatings(in: page.comments, with: fullRatings)
                }
            }
        }
        if target.authorID != nil {
            let unfilteredHTML: String?
            do {
                unfilteredHTML = try await loadUnfilteredChapterCommentHTML(for: target)
            } catch {
                YamiboLog.forum.warning("loadChapterComments: failed to fetch unfiltered chapter comment HTML; same-page replies will be omitted: \(error)")
                unfilteredHTML = nil
            }
            if let unfilteredHTML {
                let unfilteredView = (try? ChapterCommentsHTMLParser.currentView(
                    html: unfilteredHTML,
                    fallback: target.view
                )) ?? target.view
                var unfilteredTarget = target
                unfilteredTarget.view = unfilteredView
                let unfilteredPage = try ChapterCommentsHTMLParser.parseInitialPage(
                    html: unfilteredHTML,
                    target: unfilteredTarget
                )
                page = Self.appendingSamePageReplies(from: unfilteredPage, to: page)
            }
        }
        return page
    }

    public func loadMoreChapterComments(
        for target: ReaderChapterCommentTarget,
        view: Int
    ) async throws -> ChapterCommentsPage {
        let html = try await client.fetchThreadById(
            tid: target.threadID,
            page: view,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: view)
    }

    private func loadUnfilteredChapterCommentHTML(for target: ReaderChapterCommentTarget) async throws -> String {
        if let findPostURL = YamiboRoute.findPostURL(threadID: target.threadID, postID: target.ownerPostID),
           let html = try? await client.fetchHTML(
               url: findPostURL,
               cachePolicy: .reloadIgnoringLocalCacheData
           ) {
            return html
        }
        return try await client.fetchThreadById(
            tid: target.threadID,
            page: target.view,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    private static func replacingPreviewRatings(
        in comments: [ChapterComment],
        with fullRatings: [ChapterComment]
    ) -> [ChapterComment] {
        let insertionIndex = comments.firstIndex { $0.source == .ratingReason }
            ?? comments.firstIndex { $0.source != .postComment }
            ?? comments.count
        let retainedBeforeInsertion = comments[..<insertionIndex].filter { $0.source != .ratingReason }.count
        var merged = comments.filter { $0.source != .ratingReason }
        merged.insert(contentsOf: fullRatings, at: retainedBeforeInsertion)
        return merged
    }

    private static func appendingSamePageReplies(
        from unfilteredPage: ChapterCommentsPage,
        to page: ChapterCommentsPage
    ) -> ChapterCommentsPage {
        let existingIDs = Set(page.comments.map(\.id))
        let replies = unfilteredPage.comments.filter { comment in
            comment.source == .reply && !existingIDs.contains(comment.id)
        }
        return ChapterCommentsPage(
            target: page.target,
            comments: page.comments + replies,
            isBoundaryClosed: unfilteredPage.isBoundaryClosed,
            nextView: unfilteredPage.nextView
        )
    }

}
