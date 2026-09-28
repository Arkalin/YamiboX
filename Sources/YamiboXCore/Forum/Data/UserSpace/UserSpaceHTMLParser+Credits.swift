import CryptoKit
import Foundation

extension UserSpaceHTMLParser {
    /// Discuz X3.5 touch template `home/spacecp_credit_log.htm`.
    static func parseCreditLog(from html: String) throws -> CreditLogPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let rows = document.selectAll(".home_credit_log > ul > li")

        guard !rows.isEmpty else {
            let hasCreditNavigation = document.selectAll("#dhnavs a[href]").contains { link in
                guard let url = link.attrURL("href") else { return false }
                return YamiboDomain.isYamiboHost(url)
                    && url.queryItemValue("mod") == "spacecp"
                    && url.queryItemValue("ac") == "credit"
                    && url.queryItemValue("op") == "log"
            }
            let emptyText = document.firstText(".empty-box h4")
            if hasCreditNavigation, let emptyText, ["现在还没有记录", "現在還沒有記錄"].contains(emptyText) {
                return CreditLogPage(entries: [], pageNavigation: parsePageNavigation(in: document))
            }
            if let message = document.firstText("#messagetext, .jump_c, .alert_error") {
                throw YamiboError.underlying(message)
            }
            throw creditLogParsingError()
        }

        var occurrences: [String: Int] = [:]
        let entries = try rows.map { row in
            let paragraphs = row.children().array().filter { $0.tagName() == "p" }
            guard let heading = paragraphs.first,
                  let descriptionElement = row.selectFirst(".txt"),
                  let timeText = row.firstText(".mtime") else {
                throw creditLogParsingError()
            }
            let columns = heading.children().array().filter { $0.tagName() == "span" }
            guard columns.count == 2, let operation = columns[0].normalizedText().nilIfBlank else {
                throw creditLogParsingError()
            }
            let changes = creditChanges(in: columns[1])
            guard !changes.isEmpty else { throw creditLogParsingError() }
            let description = try creditDescription(in: descriptionElement)

            // The touch template exposes no log ID. Keep identical transactions,
            // disambiguating them by occurrence rather than dropping duplicates.
            let seed = [operation, columns[1].normalizedText(), description.text, timeText]
                + description.links.map { $0.url.absoluteString }
            let digest = SHA256.hash(data: Data(seed.joined(separator: "\u{1F}").utf8))
                .map { String(format: "%02x", $0) }.joined()
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            return CreditLogEntry(
                id: "\(digest)-\(occurrence)",
                operation: operation,
                changes: changes,
                description: description,
                timeText: timeText
            )
        }
        return CreditLogPage(entries: entries, pageNavigation: parsePageNavigation(in: document))
    }

    private static func creditChanges(in element: Element) -> [CreditLogChange] {
        var lines = [""]
        for node in element.getChildNodes() {
            if let child = node as? Element, child.tagName() == "br" {
                lines.append("")
            } else {
                lines[lines.count - 1] += node.text()
            }
        }
        return lines.compactMap { line in
            guard let text = line.htmlNormalized.nilIfBlank else { return nil }
            guard let match = HTMLTextExtractor.firstMatch(
                pattern: #"^(.+?)\s*([+-])\s*(\d[\d,]*)\s*(.*)$"#,
                in: text
            ), match.count == 5 else {
                // For example, a reward reset has a label but no numeric delta.
                return CreditLogChange(name: text, valueText: "")
            }
            let signedValue = match[2] + match[3]
            let suffix = match[4].nilIfBlank.map { " " + $0 } ?? ""
            return CreditLogChange(
                name: match[1].htmlNormalized,
                valueText: signedValue + suffix,
                amount: Int(signedValue.replacingOccurrences(of: ",", with: ""))
            )
        }
    }

    private static func creditDescription(in element: Element) throws -> ForumThreadTextBlock {
        // Reuse the forum text parser for entity decoding and link ranges, but
        // discard website font/color styling on this compact native surface.
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(in: element)
        var result = ForumThreadTextBlock(text: "")
        for block in blocks {
            guard case let .text(textBlock) = block.kind else { continue }
            if !result.text.isEmpty { result.text += "\n" }
            let offset = result.text.count
            result.text += textBlock.text
            result.links += textBlock.links.compactMap { link in
                guard ["http", "https"].contains(link.url.scheme?.lowercased() ?? "") else { return nil }
                return ForumThreadTextLink(start: offset + link.start, length: link.length, url: link.url)
            }
        }
        if result.text.isEmpty {
            result.text = element.normalizedText()
        }
        return result
    }

    private static func creditLogParsingError() -> YamiboError {
        .parsingFailed(context: L10n.string("credit_log.title"))
    }
}
