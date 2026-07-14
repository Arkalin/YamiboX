import Foundation

public actor ForumThreadReaderRepository: ThreadCoverPageResolving {
    private let client: YamiboClient
    private let cacheStore: ForumCacheStore

    init(client: YamiboClient, cacheStore: ForumCacheStore = ForumCacheStore()) {
        self.client = client
        self.cacheStore = cacheStore
    }

    public func fetchThreadPage(context: ThreadNovelLaunchContext, page: Int = 1) async throws -> ForumThreadPage {
        let html = try await client.fetchThreadById(
            tid: context.thread.tid,
            page: page,
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        let parsed = try ForumThreadPageHTMLParser.parsePage(
            from: html,
            thread: context.thread,
            fallbackTitle: context.title
        )
        do {
            try await cacheStore.saveThreadPage(parsed, thread: context.thread, pageNumber: page, authorID: nil)
        } catch {
            YamiboLog.forum.error("fetchThreadPage: failed to cache thread page tid=\(context.thread.tid, privacy: .public) page=\(page, privacy: .public): \(error)")
        }
        return parsed
    }

    public func fetchNovelThreadPage(context: NovelDetailLaunchContext, page: Int = 1) async throws -> ForumThreadPage {
        let html = try await client.fetchThreadById(
            tid: context.thread.tid,
            authorID: context.authorID,
            page: page,
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        let parsed = try ForumThreadPageHTMLParser.parsePage(
            from: html,
            thread: context.thread,
            fallbackTitle: context.title
        )
        do {
            try await cacheStore.saveThreadPage(parsed, thread: context.thread, pageNumber: page, authorID: context.authorID)
        } catch {
            YamiboLog.forum.error("fetchNovelThreadPage: failed to cache thread page tid=\(context.thread.tid, privacy: .public) page=\(page, privacy: .public): \(error)")
        }
        return parsed
    }

    public func cachedThreadPage(context: ThreadNovelLaunchContext, page: Int = 1) async -> ForumThreadPage? {
        await cacheStore.loadThreadPage(thread: context.thread, page: page, authorID: nil)
    }

    public func cachedNovelThreadPage(context: NovelDetailLaunchContext, page: Int = 1) async -> ForumThreadPage? {
        await cacheStore.loadThreadPage(thread: context.thread, page: page, authorID: context.authorID)
    }

    public func clearCachedThreadPages(thread: ThreadIdentity) async throws {
        try await cacheStore.clearThreadPages(thread: thread)
    }

    public func storeNovelThreadPage(_ page: ForumThreadPage, context: NovelDetailLaunchContext, pageNumber: Int = 1) async throws {
        try await cacheStore.saveThreadPage(page, thread: context.thread, pageNumber: pageNumber, authorID: context.authorID)
    }

    public func cachedThreadPage(
        thread: ThreadIdentity,
        title _: String,
        authorID: String?,
        page: Int
    ) async -> ForumThreadPage? {
        await cacheStore.loadThreadPage(thread: thread, page: page, authorID: authorID)
    }

    public func fetchThreadPage(
        thread: ThreadIdentity,
        title: String,
        authorID: String?,
        page: Int
    ) async throws -> ForumThreadPage {
        try await fetchNovelThreadPage(
            context: NovelDetailLaunchContext(
                thread: thread,
                title: title,
                authorID: authorID
            ),
            page: page
        )
    }

    public func fetchRatingResults(threadID: String, postID: String) async throws -> ForumThreadRatingResultsPage {
        let html = try await client.fetchHTML(
            for: .threadRatingResults(tid: threadID, pid: postID),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return try ForumThreadPageHTMLParser.parseRatingResults(from: html)
    }

    public func fetchRateOptions(threadID: String, postID: String) async throws -> ForumThreadRateOptionsPage {
        let html = try await client.fetchHTML(
            for: .threadRateOptions(tid: threadID, pid: postID),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return try ForumThreadPageHTMLParser.parseRateOptions(from: html)
    }

    public func fetchPollVoters(
        threadID: String,
        optionID: String?,
        page: Int = 1
    ) async throws -> ForumThreadPollVotersPage {
        let html = try await client.fetchHTML(
            for: .threadPollVoters(tid: threadID, pollOptionID: optionID, page: page),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return try ForumThreadPageHTMLParser.parsePollVoters(
            from: html,
            threadID: threadID,
            requestedOptionID: optionID
        )
    }

    public func votePoll(
        forumID: String,
        threadID: String,
        optionIDs: [String],
        formHash: String
    ) async throws -> String {
        let normalizedForumID = forumID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFormHash = formHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOptionIDs = optionIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedForumID.isEmpty,
              !normalizedThreadID.isEmpty,
              !normalizedFormHash.isEmpty,
              !normalizedOptionIDs.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("forum.thread.poll"))
        }

        let fields = [
            ("formhash", normalizedFormHash),
            ("pollsubmit", "true"),
            ("quickforward", "yes")
        ] + normalizedOptionIDs.map { ("pollanswers[]", $0) }

        let html = try await client.submitForm(
            for: .threadPollVote(fid: normalizedForumID, tid: normalizedThreadID),
            fields: fields
        )
        return try ForumThreadPageHTMLParser.parseThreadActionResult(
            from: html,
            context: L10n.string("forum.thread.poll")
        )
    }

    public func ratePost(
        threadID: String,
        postID: String,
        score: Int,
        reason: String,
        formHash: String,
        noticeAuthor: Bool
    ) async throws -> String {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPostID = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFormHash = formHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty,
              !normalizedPostID.isEmpty,
              !normalizedFormHash.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("forum.thread.ratings"))
        }

        var fields = [
            ("formhash", normalizedFormHash),
            ("tid", normalizedThreadID),
            ("pid", normalizedPostID),
            ("referer", ""),
            ("handlekey", "rate"),
            ("score1", String(score)),
            ("reason", reason.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        if noticeAuthor {
            fields.append(("sendreasonpm", "on"))
        }

        let html = try await client.submitForm(for: .threadRateSubmit, fields: fields)
        return try ForumThreadPageHTMLParser.parseThreadActionResult(
            from: html,
            context: L10n.string("forum.thread.ratings")
        )
    }

    public func commentPost(
        threadID: String,
        postID: String,
        message: String,
        formHash: String,
        page: Int = 1
    ) async throws -> String {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPostID = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFormHash = formHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty,
              !normalizedPostID.isEmpty,
              !normalizedMessage.isEmpty,
              !normalizedFormHash.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("forum.thread.comments"))
        }

        let html = try await client.submitForm(
            for: .threadPostComment(tid: normalizedThreadID, pid: normalizedPostID, page: page),
            fields: [
                ("formhash", normalizedFormHash),
                ("handlekey", ""),
                ("message", normalizedMessage)
            ]
        )
        return try ForumThreadPageHTMLParser.parseThreadActionResult(
            from: html,
            context: L10n.string("forum.thread.comments")
        )
    }
}
