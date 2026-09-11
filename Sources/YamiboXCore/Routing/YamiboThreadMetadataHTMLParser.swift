import Foundation

struct YamiboThreadMetadata: Hashable, Sendable {
    var tid: String?
    var fid: String?
    var title: String?
    var authorID: String?
    var sectionText: String?

    init(
        tid: String? = nil,
        fid: String? = nil,
        title: String? = nil,
        authorID: String? = nil,
        sectionText: String? = nil
    ) {
        self.tid = tid?.nilIfBlank
        self.fid = fid?.nilIfBlank
        self.title = title?.nilIfBlank
        self.authorID = authorID?.nilIfBlank
        self.sectionText = sectionText?.nilIfBlank
    }
}

enum YamiboThreadMetadataHTMLParser {
    static func parse(from html: String, url: URL) throws -> YamiboThreadMetadata {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let title = YamiboHTMLPageInspector.pageTitle(from: html)
        let sectionLink = document
            .selectAll("a[href*='mod=forumdisplay'][href*='fid='], a[href*='forum-']")
            .first { !$0.normalizedText().isEmpty }
        let sectionURL = sectionLink?.attrURL("href")
        let authorLink = document.selectFirst("a[href*='mod=space'][href*='uid='], a[href*='space-uid-']")
        let authorURL = authorLink?.attrURL("href")

        return YamiboThreadMetadata(
            tid: responseThreadID(from: url) ?? currentThreadID(in: document),
            fid: sectionURL.flatMap(YamiboForumURLIdentity.forumID(from:)) ?? forumID(from: html),
            title: title,
            authorID: authorURL.flatMap(YamiboForumURLIdentity.userID(from:)) ?? userID(from: html),
            sectionText: sectionLink?.normalizedText().nilIfBlank
        )
    }

    private static func responseThreadID(from url: URL) -> String? {
        guard ForumWebPagePolicy.requiresForumHandling(url),
              case .thread = ForumRouteResolver.resolve(url: url),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "mod" && $0.value == "redirect" }) != true else { return nil }
        return threadID(from: url)
    }

    private static func currentThreadID(in document: Document) -> String? {
        for link in document.select("link[rel=canonical], form#fastpostform[action], form#postform[action]") {
            let attribute = link.tagName() == "link" ? "href" : "action"
            if let url = link.attrURL(attribute), ForumWebPagePolicy.requiresForumHandling(url),
               let tid = link.tagName() == "link" ? responseThreadID(from: url) : threadID(from: url) { return tid }
        }
        if let value = document.selectFirst("form#fastpostform input[name=tid], form#postform input[name=tid]")?.attr("value"),
           !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), Int(value).map({ $0 > 0 }) == true {
            return value
        }
        return nil
    }

    private static func forumID(from text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"(?:[?&;]fid=|forum-)(\d+)"#, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func threadID(from url: URL) -> String? {
        YamiboThreadURLCanonicalizer.threadID(from: url)
    }

    private static func userID(from text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"(?:[?&;]uid=|space-uid-)(\d+)"#, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }
}
