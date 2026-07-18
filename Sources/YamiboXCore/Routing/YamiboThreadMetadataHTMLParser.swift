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
            tid: threadID(from: url) ?? threadID(from: html),
            fid: sectionURL.flatMap(YamiboForumURLIdentity.forumID(from:)) ?? forumID(from: html),
            title: title,
            authorID: authorURL.flatMap(YamiboForumURLIdentity.userID(from:)) ?? userID(from: html),
            sectionText: sectionLink?.normalizedText().nilIfBlank
        )
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

    private static func threadID(from text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"(?:[?&;]tid=|thread-)(\d+)"#, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func userID(from text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"(?:[?&;]uid=|space-uid-)(\d+)"#, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }
}
