import Foundation

/// Facade over the thread-page parser family.
///
/// Each entry point guards page readability (login/flood interstitials), unwraps
/// the Discuz AJAX CDATA envelope where applicable, delegates extraction to the
/// part parsers (`ForumThreadPostsParser`, `ForumThreadPollParser`,
/// `ForumThreadRatingParser`, `ForumThreadPageMetadataParser`, ...), and surfaces
/// server-side error messages as `YamiboError`.
enum ForumThreadPageHTMLParser {
    static func parsePage(
        from html: String,
        thread: ThreadIdentity,
        fallbackTitle: String?
    ) throws -> ForumThreadPage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let title = ForumThreadTitleSanitizer.sanitize(YamiboHTMLPageInspector.pageTitle(from: html))
            ?? ForumThreadTitleSanitizer.sanitize(fallbackTitle)
            ?? L10n.string("forum.default_title")
        let posts = try ForumThreadPostsParser.posts(in: document)
        guard !posts.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.thread_page"))
        }
        let stats = ForumThreadPageMetadataParser.threadStats(in: document)

        return ForumThreadPage(
            thread: thread,
            title: title,
            posts: posts,
            pageNavigation: ForumThreadPageMetadataParser.pageNavigation(in: document),
            totalViews: stats.totalViews,
            totalReplies: stats.totalReplies,
            forumID: ForumThreadPageMetadataParser.forumID(in: document),
            forumName: ForumThreadPageMetadataParser.forumName(in: document),
            formHash: DiscuzFormHashParser.formHash(in: document, html: html)
        )
    }

    static func parseRatingResults(from html: String) throws -> ForumThreadRatingResultsPage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let body = extractCData(from: html) ?? html
        let document = try KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString)
        let ratings = ForumThreadRatingParser.ratingResultRows(in: document)
        guard !ratings.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("forum.thread.ratings_all"))
        }

        return ForumThreadRatingResultsPage(
            ratings: ratings,
            totalScore: ForumThreadRatingParser.resultsTotalScore(in: document, ratings: ratings)
        )
    }

    static func parseRateOptions(from html: String) throws -> ForumThreadRateOptionsPage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let body = extractCData(from: html) ?? html
        let document = try KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString)
        let page = ForumThreadRatingParser.rateOptionsPage(in: document)
        if page.availableScores.isEmpty && page.defaultReasons.isEmpty,
           let message = parseMessageText(from: html) {
            throw YamiboError.underlying(message)
        }
        return page
    }

    static func parsePollVoters(
        from html: String,
        threadID: String,
        requestedOptionID: String? = nil
    ) throws -> ForumThreadPollVotersPage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let body = extractCData(from: html) ?? html
        let document = try KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString)
        let requestedOptionID = requestedOptionID?.nilIfBlank
        let options = ForumThreadPollParser.voterOptions(in: document, requestedOptionID: requestedOptionID)
        let selectedOptionID = ForumThreadPollParser.selectedOptionID(in: document)
            ?? requestedOptionID
            ?? options.first?.id
        let voters = ForumThreadPollParser.voters(in: document)
        guard !options.isEmpty || !voters.isEmpty else {
            if let message = parseMessageText(from: html) {
                throw YamiboError.underlying(message)
            }
            throw YamiboError.parsingFailed(context: L10n.string("forum.thread.poll_voters"))
        }

        return ForumThreadPollVotersPage(
            threadID: threadID,
            selectedOptionID: selectedOptionID,
            pollOptions: options,
            voters: voters,
            pageNavigation: ForumThreadPageMetadataParser.pageNavigation(in: document)
        )
    }

    static func parseThreadActionResult(
        from html: String,
        context: String = L10n.string("context.thread_page"),
        requiresExplicitSuccess: Bool = false
    ) throws -> String {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let body = extractCData(from: html) ?? html
        let document = try KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString)
        let message = parseMessageText(from: html)
            ?? document.firstText(".jump_c, .alert_info, .messagetext, .showmessage, #messagetext, .wp, body")
        guard let message else {
            throw YamiboError.parsingFailed(context: context)
        }
        if (!html.contains("succeedhandle") && html.contains("<root"))
            || message.contains("失败")
            || message.contains("失敗")
            || message.contains("错误")
            || message.contains("錯誤")
            || message.localizedCaseInsensitiveContains("error") {
            throw YamiboError.underlying(message)
        }
        if requiresExplicitSuccess {
            let failures = ["未成功", "不成功", "抱歉", "无法", "不能", "无权", "没有权限", "无效", "不足", "禁止", "不允许"]
            guard !failures.contains(where: message.contains) else { throw YamiboError.underlying(message) }
            let successes = ["评分成功", "評分成功", "点评成功", "點評成功", "评论成功", "評論成功", "操作成功", "提交成功", "等待审核", "等待審核", "进入审核"]
            let hasSuccessCallback = html.contains("succeedhandle_") && html.contains("<script")
            guard hasSuccessCallback || successes.contains(where: message.contains) else { throw ForumPageError.submissionUnconfirmed }
        }
        return message
    }

    /// Payload of the `<root><![CDATA[...]]></root>` envelope Discuz wraps AJAX responses in.
    private static func extractCData(from html: String) -> String? {
        HTMLTextExtractor.discuzAjaxPayload(from: html)
    }

    /// Human-readable status/error message embedded in a Discuz response, if any.
    private static func parseMessageText(from html: String) -> String? {
        let body = extractCData(from: html) ?? html
        guard let document = try? KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString) else { return nil }
        return document.firstText("#messagetext p")
            ?? document.firstText("#messagetext, .messagetext, .alert_info, .jump_c, .showmessage")
    }
}
