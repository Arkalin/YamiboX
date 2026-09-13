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
            page: target.view,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        var page = try LoadDiagnosticError.parsing(html: html, context: "ChapterCommentsHTMLParser.parseInitialPage") {
            try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        }
        if target.authorID != nil {
            let unfilteredHTML: String?
            do {
                unfilteredHTML = try await loadUnfilteredChapterCommentHTML(for: target)
            } catch {
                if Task.isCancelled || LoadDiagnosticError.isCancellation(error) { throw error }
                YamiboLog.forum.warning("loadChapterComments: failed to fetch unfiltered chapter comment HTML; same-page replies will be omitted: \(error)")
                unfilteredHTML = nil
                page.isBoundaryClosed = false
                page.nextView = nil
                page.isThreadEndConfirmed = false
                page.needsInitialRetry = true
            }
            if let unfilteredHTML {
                let unfilteredView = (try? ChapterCommentsHTMLParser.currentView(
                    html: unfilteredHTML,
                    fallback: target.view
                )) ?? target.view
                var unfilteredTarget = target
                unfilteredTarget.view = unfilteredView
                let unfilteredPage = try LoadDiagnosticError.parsing(html: unfilteredHTML, context: "ChapterCommentsHTMLParser.parseInitialPage") {
                    try ChapterCommentsHTMLParser.parseInitialPage(
                        html: unfilteredHTML,
                        target: unfilteredTarget,
                        isUnfiltered: true
                    )
                }
                page = Self.appendingSamePageReplies(from: unfilteredPage, to: page)
            }
        }
        return page
    }

    public func loadRatingReasons(
        for target: ReaderChapterCommentTarget,
        request: ChapterCommentRatingRequest
    ) async throws -> [ChapterComment] {
        let html = try await client.fetchHTML(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData)
        var postTarget = target
        postTarget.ownerPostID = request.postID
        let ratings = try LoadDiagnosticError.parsing(html: html, context: "ChapterCommentsHTMLParser.parseFullRatingReasonsPage") {
            try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(html: html, target: postTarget)
        }
        return ratings.map { rating in
            var result = rating
            if let uid = rating.authorUID, let authorID = target.authorID { result.isThreadAuthor = uid == authorID }
            return result
        }
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
        return try LoadDiagnosticError.parsing(html: html, context: "ChapterCommentsHTMLParser.parseContinuationPage") {
            try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: view)
        }
    }

    private func loadUnfilteredChapterCommentHTML(for target: ReaderChapterCommentTarget) async throws -> String {
        if let findPostURL = YamiboRoute.findPostURL(threadID: target.threadID, postID: target.ownerPostID) {
            do {
                return try await client.fetchHTML(url: findPostURL, cachePolicy: .reloadIgnoringLocalCacheData)
            } catch {
                if Task.isCancelled || LoadDiagnosticError.isCancellation(error) { throw error }
            }
        }
        return try await client.fetchThreadById(
            tid: target.threadID,
            page: target.view,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    private static func appendingSamePageReplies(
        from unfilteredPage: ChapterCommentsPage,
        to page: ChapterCommentsPage
    ) -> ChapterCommentsPage {
        let existingIDs = Set(page.comments.map(\.id))
        let replies = unfilteredPage.comments.filter { comment in
            (comment.source == .reply || comment.postID != page.target.ownerPostID) && !existingIDs.contains(comment.id)
        }
        return ChapterCommentsPage(
            target: page.target,
            comments: page.comments + replies,
            isBoundaryClosed: unfilteredPage.isBoundaryClosed,
            nextView: unfilteredPage.nextView,
            isThreadEndConfirmed: unfilteredPage.isThreadEndConfirmed,
            pendingRatings: Array(Set((page.pendingRatings ?? []) + (unfilteredPage.pendingRatings ?? []))).sorted { $0.postID < $1.postID },
            needsInitialRetry: unfilteredPage.needsInitialRetry
        )
    }

}
