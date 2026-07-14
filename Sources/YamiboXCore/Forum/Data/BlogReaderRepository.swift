import Foundation

public actor BlogReaderRepository {
    private let client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    public func fetchBlogPage(blogID: String, uid: String?, page: Int) async throws -> BlogReaderPage {
        let normalizedBlogID = blogID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBlogID.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.blog_reader"))
        }
        let html = try await client.fetchHTML(
            for: .blog(blogID: normalizedBlogID, uid: normalized(uid), page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try BlogReaderHTMLParser.parsePage(from: html, blogID: normalizedBlogID, uidHint: uid)
    }

    public func postBlogComment(blogID: String, uid: String, message: String, formHash: String) async throws -> String {
        let normalizedBlogID = blogID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFormHash = formHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBlogID.isEmpty,
              !normalizedUID.isEmpty,
              !normalizedMessage.isEmpty,
              !normalizedFormHash.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.blog_reader"))
        }

        let html = try await client.submitForm(
            for: .blogComment(blogID: normalizedBlogID, uid: normalizedUID),
            fields: [
                ("formhash", normalizedFormHash),
                ("commentsubmit", "true"),
                ("id", normalizedBlogID),
                ("idtype", "blogid"),
                ("uid", normalizedUID),
                ("message", normalizedMessage)
            ]
        )
        return try BlogReaderHTMLParser.parseCommentResult(from: html)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
