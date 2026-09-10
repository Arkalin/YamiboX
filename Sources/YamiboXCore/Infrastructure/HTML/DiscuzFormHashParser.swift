import Foundation

/// The single site-wide extraction point for Discuz's `formhash` anti-CSRF
/// token. Five parsers/repositories used to carry private copies that drifted
/// (hex-only character classes, missing fallbacks); new POST flows should call
/// this instead of re-deriving the patterns. Behavior is the union of the old
/// copies, ordered most-targeted first: the hidden form input, then the logout
/// link (profile pages render no suitable form), then raw-HTML scans for
/// markup the DOM pass failed to materialize, and the touch template's literal
/// AJAX parameters when the page has no form or logout link.
enum DiscuzFormHashParser {
    static func formHash(in document: Document, html: String) -> String? {
        if let value = document.selectFirst("input[name=formhash]")?.attrText("value") {
            return value
        }
        if let href = document.selectFirst(".btn_exit a")?.attrText("href"),
           let value = HTMLTextExtractor.firstMatch(pattern: #"formhash=([A-Za-z0-9]+)"#, in: href)?
           .dropFirst()
           .first?
           .nilIfBlank {
            return value
        }
        return markupFormHash(inHTML: html) ?? ajaxFormHash(in: document)
    }

    /// For callers that hold only raw HTML and never build a document
    /// (e.g. the favorites delete-form fetch).
    static func formHash(inHTML html: String) -> String? {
        if let value = markupFormHash(inHTML: html) { return value }
        guard let document = try? KannaSoup.parse(html) else { return nil }
        return ajaxFormHash(in: document)
    }

    private static func markupFormHash(inHTML html: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: #"name=["']formhash["']\s+value=["']([^"']+)["']"#, in: html)?
            .dropFirst()
            .first?
            .nilIfBlank
            ?? HTMLTextExtractor.firstMatch(pattern: #"formhash=([A-Za-z0-9]+)"#, in: html)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func ajaxFormHash(in document: Document) -> String? {
        struct Parameters: Decodable { let formhash: String }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        // touch/forum/viewthread.htm embeds the token in the favorite AJAX data.
        // Decode only literal parameters in inline scripts, never execute JavaScript.
        for script in document.select("script:not([src])") {
            for match in HTMLTextExtractor.matches(pattern: #"\bdata\s*:\s*(\{[^{}]*\})"#, in: script.html()) {
                guard let literal = match.dropFirst().first,
                      let parameters = try? decoder.decode(Parameters.self, from: Data(literal.utf8)),
                      let token = parameters.formhash.nilIfBlank else { continue }
                return token
            }
        }
        return nil
    }
}
