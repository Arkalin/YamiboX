import Foundation

struct NovelReaderCacheIdentity: Hashable, Codable, Sendable {
    let threadID: String
    let threadKey: String
    let authorID: String?
    let view: Int

    var variantKey: String {
        authorID.map { "author:\($0)" } ?? "author:none"
    }

    var cacheKey: String {
        "\(threadKey)#\(variantKey)#\(view)"
    }

    init(threadID: String, view: Int, authorID: String?) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "NovelReaderCacheIdentity requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.threadKey = "tid:\(normalizedThreadID)"
        self.authorID = Self.normalizedAuthorID(authorID)
        self.view = max(1, view)
    }

    init(request: NovelPageRequest) {
        self.init(
            threadID: request.threadID,
            view: request.view,
            authorID: request.authorID
        )
    }

    init(projection: NovelReaderProjection) {
        self.init(
            threadID: projection.threadID,
            view: projection.view,
            authorID: projection.resolvedAuthorID
        )
    }

    private static func normalizedAuthorID(_ authorID: String?) -> String? {
        let trimmed = authorID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
