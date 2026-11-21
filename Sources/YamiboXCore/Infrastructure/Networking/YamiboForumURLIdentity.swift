import Foundation

enum YamiboForumURLIdentity {
    static func threadID(from href: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"tid=(\d+)"#, in: href)?.dropFirst().first
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-"#, in: href)?.dropFirst().first
    }

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

    static func userID(from url: URL) -> String? {
        url.queryItemValue("uid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"space-uid-(\d+)"#, in: url.absoluteString)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    static func forumID(from url: URL) -> String? {
        url.queryItemValue("fid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"forum-(\d+)-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first?
            .nilIfBlank
    }
}
