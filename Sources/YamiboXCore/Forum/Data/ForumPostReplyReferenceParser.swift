import Foundation

public struct ForumPostReplyReference: Codable, Hashable, Sendable {
    public var postID: String?
    public var authorName: String?
    public var postedAt: String?

    public init(postID: String? = nil, authorName: String? = nil, postedAt: String? = nil) {
        self.postID = postID
        self.authorName = authorName
        self.postedAt = postedAt
    }
}

enum ForumPostReplyReferenceParser {
    static func parse(in blocks: [ForumThreadContentBlock]) -> ForumPostReplyReference? {
        for block in blocks {
            switch block.kind {
            case let .quote(children):
                let texts = children.compactMap { child -> ForumThreadTextBlock? in
                    if case let .text(text) = child.kind { return text }
                    return nil
                }
                let header = parseHeader(texts.map(\.text).joined(separator: " "))
                for link in texts.flatMap(\.links) {
                    if let pid = postID(in: link.url) {
                        return .init(postID: pid, authorName: header?.authorName, postedAt: header?.postedAt)
                    }
                }
                if let reference = header ?? parse(in: children) { return reference }
            case let .collapse(_, children), let .locked(_, children):
                if let reference = parse(in: children) { return reference }
            case let .table(rows):
                if let reference = parse(in: rows.flatMap { $0 }.flatMap(\.blocks)) { return reference }
            default:
                break
            }
        }
        return nil
    }

    static func parse(in body: Element, threadID: String? = nil) -> ForumPostReplyReference? {
        for quote in body.selectAll(".quote, blockquote") {
            guard !([quote] + quote.parents()).contains(where: { element in
                let style = element.attr("style").lowercased().filter { !$0.isWhitespace }
                return element.hasAttribute("hidden") || element.hasClass("jammer")
                    || style.contains("display:none") || style.contains("visibility:hidden")
            }) else { continue }
            let header = parseHeader(quote.normalizedText())
            for link in quote.selectAll("a[href]") {
                guard let url = link.attrURL("href"),
                      let pid = postID(in: url) else { continue }
                let quotedThread = url.queryItemValue("ptid") ?? url.queryItemValue("tid")
                if let threadID, let quotedThread, quotedThread != threadID { return nil }
                return ForumPostReplyReference(postID: pid, authorName: header?.authorName, postedAt: header?.postedAt)
            }
            if let header { return header }
        }
        return nil
    }

    private static func postID(in url: URL) -> String? {
        guard YamiboDomain.isYamiboHost(url),
              let pid = url.queryItemValue("pid"), !pid.isEmpty, pid.allSatisfy(\.isNumber) else { return nil }
        return pid
    }

    static func parseHeader(_ text: String) -> ForumPostReplyReference? {
        let pattern = #"^\s*(.+?)\s+(?:发表于|發表於|發表于|发表於)\s+(\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2}(?::\d{2})?)"#
        guard let match = HTMLTextExtractor.firstMatch(pattern: pattern, in: text), match.count >= 3 else { return nil }
        return ForumPostReplyReference(authorName: match[1].htmlNormalized, postedAt: timestamp(match[2]))
    }

    static func timestamp(_ text: String) -> String? {
        guard let match = HTMLTextExtractor.firstMatch(pattern: #"(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2})"#, in: text),
              match.count == 6 else { return nil }
        return match.dropFirst().compactMap(Int.init).map(String.init).joined(separator: ":")
    }
}
