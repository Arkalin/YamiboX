import Foundation

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
