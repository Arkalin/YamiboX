import Foundation

actor ForumBlacklistRepository: ForumBlacklistRemoteOperating {
    private let client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    func fetchPage(page: Int) async throws -> ForumBlacklistPage {
        let html = try await client.fetchHTML(for: .forumBlacklist(page: page), cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "ForumBlacklistHTMLParser.parse") {
            try ForumBlacklistHTMLParser.parse(html)
        }
    }

    func fetchUser(uid: String?) async throws -> UserSpaceProfile {
        let html = try await client.fetchHTML(for: .userSpaceProfile(uid: uid), cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "ForumBlacklistRepository.fetchUser") {
            let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
            // Unlike a navigation title hint, this name comes from the actual profile.
            guard let name = document.firstText(".avatar_bg .name"), !name.isEmpty else {
                try YamiboHTMLPageInspector.ensureReadable(html)
                throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
            }
            let profile = try UserSpaceHTMLParser.parseProfile(from: html)
            guard Int(profile.uid).map({ $0 > 0 }) == true,
                  uid == nil || uid == profile.uid else {
                throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
            }
            return profile
        }
    }

    func add(username: String, formHash: String) async throws {
        let html = try await client.submitForm(for: .forumBlacklistAdd, fields: [
            ("username", username), ("formhash", formHash), ("blacklistsubmit", "true")
        ])
        _ = try LoadDiagnosticError.parsing(html: html, context: "ForumBlacklistRepository.add") {
            try DiscuzActionResultParser.successMessage(from: html, emptyPageContext: L10n.string("blacklist.title"))
        }
    }

    func remove(_ entry: ForumBlacklistEntry) async throws {
        guard ForumBlacklistHTMLParser.deleteUID(entry.deleteURL) == entry.uid else {
            throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
        }
        let html = try await client.fetchHTML(url: entry.deleteURL, cachePolicy: .reloadIgnoringLocalCacheData)
        _ = try LoadDiagnosticError.parsing(html: html, context: "ForumBlacklistRepository.remove") {
            try DiscuzActionResultParser.successMessage(from: html, emptyPageContext: L10n.string("blacklist.title"))
        }
    }
}
