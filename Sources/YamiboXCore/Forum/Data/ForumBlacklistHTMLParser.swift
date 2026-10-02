import Foundation

enum ForumBlacklistHTMLParser {
    static func parse(_ html: String) throws -> ForumBlacklistPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        // The desktop form is present even on an empty list. A generic error,
        // login page or an unsupported touch template must never clear the cache.
        guard let form = document.selectFirst("form[action*='op=blacklist']"),
              form.selectFirst("input[name=blacklistsubmit]") != nil,
              let hash = DiscuzFormHashParser.formHash(in: document, html: html) else {
            throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
        }

        var entries: [ForumBlacklistEntry] = []
        var seen = Set<String>()
        for row in document.selectAll("#friend_ul li, .buddy li, .friendlist li") {
            guard let link = row.selectFirst("a[href*='op=blacklist'][href*='subop=delete']"),
                  let url = link.attrURL("href"),
                  let uid = deleteUID(url) else {
                throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
            }
            // Interaction menus also link to this profile ("visit", "view
            // profile"). Only the primary heading link carries its username.
            let name = row.selectAll("h4 > a[href]").first { link in
                guard let profileURL = link.attrURL("href") else { return false }
                return !profileURL.absoluteString.contains("spacecp")
                    && YamiboForumURLIdentity.userID(from: profileURL) == uid
                    && !link.normalizedText().isEmpty
            }?.normalizedText()
            guard let name, !name.isEmpty else {
                throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
            }
            guard seen.insert(uid).inserted else { continue }
            entries.append(ForumBlacklistEntry(
                uid: uid, username: name,
                avatarURL: row.firstURL("img[src]", attribute: "src"), deleteURL: url
            ))
        }
        let navigation = UserSpaceHTMLParser.parsePageNavigation(in: document)
        let deleteLinks = document.selectAll("a[href*='op=blacklist'][href*='subop=delete']")
        guard deleteLinks.count == entries.count else {
            throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
        }
        if document.selectFirst(".pg") != nil, navigation?.totalPages == nil {
            throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
        }
        return ForumBlacklistPage(entries: entries, navigation: navigation, formHash: hash)
    }

    static func deleteUID(_ url: URL) -> String? {
        guard YamiboDomain.isForumURL(url), url.lastPathComponent == "home.php",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard ["mod", "ac", "op", "subop", "uid"].allSatisfy({ name in
            items.filter { $0.name == name }.count == 1
        }) else { return nil }
        guard value("mod") == "spacecp", value("ac") == "friend", value("op") == "blacklist",
              value("subop") == "delete", let uid = value("uid"),
              let numericUID = Int(uid), numericUID > 0 else { return nil }
        return uid
    }
}
