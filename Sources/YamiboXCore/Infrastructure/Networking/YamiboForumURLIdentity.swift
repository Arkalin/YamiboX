import Foundation

/// The single module-wide reader of user identity from Discuz profile URLs
/// (`uid=`/`space-uid-N`). Parsers should call these instead of growing
/// private URL regexes — per-parser copies are how the extraction rules
/// drifted apart in the first place.
enum YamiboForumURLIdentity {
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
