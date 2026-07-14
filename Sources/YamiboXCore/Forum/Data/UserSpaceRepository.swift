import Foundation

public actor UserSpaceRepository {
    private let client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    public func fetchProfile(uid: String?, titleHint: String?) async throws -> UserSpaceProfile {
        let html = try await client.fetchHTML(
            for: .userSpaceProfile(uid: normalized(uid)),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseProfile(from: html, uidHint: uid, titleHint: titleHint)
    }

    public func fetchThreads(uid: String?, page: Int) async throws -> UserSpaceThreadPage {
        let html = try await client.fetchHTML(
            for: .userSpaceThreads(uid: normalized(uid), page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseThreads(from: html)
    }

    public func fetchReplies(uid: String?, page: Int) async throws -> UserSpaceReplyPage {
        let html = try await client.fetchHTML(
            for: .userSpaceReplies(uid: normalized(uid), page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseReplies(from: html)
    }

    public func fetchBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage {
        try await fetchMyBlogs(uid: uid, page: page)
    }

    public func fetchMyBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage {
        let html = try await client.fetchHTML(
            for: .userSpaceMyBlogs(uid: normalized(uid), page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseBlogs(from: html)
    }

    public func fetchFriendBlogs(page: Int) async throws -> UserSpaceBlogPage {
        let html = try await client.fetchHTML(
            for: .userSpaceFriendBlogs(page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseBlogs(from: html)
    }

    public func fetchViewAllBlogs(filter: UserSpaceViewAllBlogFilter, page: Int) async throws -> UserSpaceBlogPage {
        let html = try await client.fetchHTML(
            for: .userSpaceViewAllBlogs(filter: filter, page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseBlogs(from: html)
    }

    public func fetchFriends(uid: String?, page: Int) async throws -> UserSpaceFriendPage {
        let html = try await client.fetchHTML(
            for: .userSpaceFriends(uid: normalized(uid), page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseFriends(from: html)
    }

    public func fetchFriendPage(type: UserSpaceFriendType, page: Int) async throws -> UserSpaceFriendPage {
        let html = try await client.fetchHTML(
            for: .userSpaceFriendPage(type: type, page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseFriends(from: html)
    }

    public func fetchPrivateMessages(page: Int) async throws -> UserSpacePrivateMessagePage {
        let html = try await client.fetchHTML(
            for: .userSpacePrivateMessages(page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parsePrivateMessageList(from: html)
    }

    public func fetchNotices(page: Int) async throws -> UserSpaceNoticePage {
        let html = try await client.fetchHTML(
            for: .userSpaceNotices(page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parseNotices(from: html)
    }

    public func fetchAddFriendForm(uid: String, nameHint: String? = nil) async throws -> UserSpaceAddFriendForm {
        let normalizedUID = normalized(uid) ?? ""
        guard !normalizedUID.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.user_space_add_friend"))
        }
        let html = try await client.fetchHTML(
            for: .userSpaceAddFriendForm(uid: normalizedUID),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return try UserSpaceHTMLParser.parseAddFriendForm(from: html, uid: normalizedUID, nameHint: nameHint)
    }

    public func addFriend(uid: String, formHash: String, note: String, groupID: Int) async throws -> String {
        let normalizedUID = normalized(uid) ?? ""
        let normalizedFormHash = formHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty, !normalizedFormHash.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.user_space_add_friend"))
        }

        let html = try await client.submitForm(
            for: .userSpaceAddFriendSubmit(uid: normalizedUID),
            fields: [
                ("formhash", normalizedFormHash),
                ("addsubmit", "true"),
                ("gid", String(groupID)),
                ("note", note.trimmingCharacters(in: .whitespacesAndNewlines))
            ]
        )
        return try UserSpaceHTMLParser.parseAddFriendResult(from: html)
    }

    public func fetchPrivateMessagePage(uid: String, page: Int? = nil, titleHint: String? = nil) async throws -> PrivateMessagePage {
        let normalizedUID = normalized(uid) ?? ""
        guard !normalizedUID.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.private_message"))
        }
        let html = try await client.fetchHTML(
            for: .privateMessage(uid: normalizedUID, page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try UserSpaceHTMLParser.parsePrivateMessagePage(from: html, toUID: normalizedUID, titleHint: titleHint)
    }

    public func sendPrivateMessage(privateMessageID: String, uid: String, formHash: String, message: String) async throws -> String {
        let normalizedUID = normalized(uid) ?? ""
        let normalizedPrivateMessageID = privateMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFormHash = formHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty,
              !normalizedPrivateMessageID.isEmpty,
              !normalizedFormHash.isEmpty,
              !normalizedMessage.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.private_message"))
        }

        let html = try await client.submitForm(
            for: .privateMessageSend(privateMessageID: normalizedPrivateMessageID, uid: normalizedUID),
            fields: [
                ("formhash", normalizedFormHash),
                ("pmsubmit", "true"),
                ("pmid", normalizedPrivateMessageID),
                ("touid", normalizedUID),
                ("message", normalizedMessage)
            ]
        )
        return try UserSpaceHTMLParser.parsePrivateMessageSendResult(from: html)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
