import Foundation

/// Shared identity extraction from Discuz thread, profile, board, and blog URLs.
/// Parsers and routing should call these instead of growing
/// private URL regexes — per-parser copies are how the extraction rules
/// drifted apart in the first place.
enum YamiboForumURLIdentity {
    /// Accepts raw HTML hrefs as well as absolute URLs, preserving the numeric
    /// query/static-link extraction used by routing and manga directory parsers.
    static func threadID(from href: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"tid=(\d+)"#, in: href)?.dropFirst().first
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-"#, in: href)?.dropFirst().first
    }

    /// Static blog links encode the author first: `blog-UID-BLOGID.html`.
    static func blogIdentity(from url: URL) -> (blogID: String, uid: String?)? {
        if url.queryItemValue("do") == "blog",
           let blogID = (url.queryItemValue("id") ?? url.queryItemValue("blogid"))?.nilIfBlank {
            return (blogID, url.queryItemValue("uid")?.nilIfBlank)
        }
        if let match = HTMLTextExtractor.firstMatch(pattern: #"blog-(\d+)-(\d+)"#, in: url.absoluteString),
           match.count >= 3 {
            return (match[2], match[1])
        }
        return nil
    }

    /// Discuz user ID from a profile URL: the `uid` query item, or the
    /// `space-uid-N` static-link form.
    static func userID(from url: URL) -> String? {
        url.queryItemValue("uid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"space-uid-(\d+)"#, in: url.absoluteString)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    /// Discuz forum (board) ID from a board URL: the `fid` query item, or the
    /// `forum-N-P.html` static-link form. Replaces identical private copies in
    /// `ForumHTMLParser` and `YamiboThreadMetadataHTMLParser` (the copies
    /// differed only by a `.nilIfBlank` on the regex capture, which a `\d+`
    /// group can never trigger — so behavior is unchanged for both).
    static func forumID(from url: URL) -> String? {
        url.queryItemValue("fid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"forum-(\d+)-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first?
            .nilIfBlank
    }
}
