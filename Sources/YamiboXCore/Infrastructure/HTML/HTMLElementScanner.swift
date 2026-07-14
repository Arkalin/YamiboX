import Foundation

/// Shared DOM-scanning layer over KannaSoup (design decision D7).
///
/// Every HTML parser used to hand-roll the same fault-tolerant access idioms
/// (`(try? select(...).first()?.text()) ?? ""`, manual trims, manual URL
/// absolutization). These extensions are the one canonical spelling of those idioms:
/// - selection never throws; failures collapse to empty results,
/// - extracted text is entity-decoded, whitespace-collapsed, and trimmed,
/// - extracted URLs are absolutized against `YamiboDomain.baseURL`.
///
/// Only high-frequency idioms live here. Low-frequency DOM operations
/// (fragment re-parsing, node removal, sibling walks) keep using KannaSoup directly.
extension Element {
    /// All elements matching `selector`; selection failures yield an empty array.
    func selectAll(_ selector: String) -> [Element] {
        (try? select(selector).array()) ?? []
    }

    /// First element matching `selector`, or nil.
    func selectFirst(_ selector: String) -> Element? {
        try? select(selector).first()
    }

    /// First element produced by any of `selectors`, tried in order.
    func selectFirst(anyOf selectors: [String]) -> Element? {
        for selector in selectors {
            if let element = selectFirst(selector) {
                return element
            }
        }
        return nil
    }

    /// Normalized, non-blank text of the first element matching `selector`, or nil.
    func firstText(_ selector: String) -> String? {
        selectFirst(selector)?.normalizedText().nilIfBlank
    }

    /// First non-blank text produced by any of `selectors`, tried in order.
    func firstText(anyOf selectors: [String]) -> String? {
        for selector in selectors {
            if let text = firstText(selector) {
                return text
            }
        }
        return nil
    }

    /// Absolute URL taken from `attribute` of the first element matching `selector`, or nil.
    func firstURL(_ selector: String, attribute: String = "href") -> URL? {
        selectFirst(selector)?.attrURL(attribute)
    }

    /// First URL produced by any of `selectors`, tried in order.
    func firstURL(anyOf selectors: [String], attribute: String = "href") -> URL? {
        for selector in selectors {
            if let url = firstURL(selector, attribute: attribute) {
                return url
            }
        }
        return nil
    }

    /// Entity-decoded, whitespace-collapsed, trimmed text of this element ("" when absent).
    func normalizedText() -> String {
        ((try? text()) ?? "").htmlNormalized
    }

    /// Trimmed, non-blank value of attribute `name`, or nil.
    func attrText(_ name: String) -> String? {
        ((try? attr(name)) ?? "").nilIfBlank
    }

    /// Absolute URL parsed from attribute `name`, or nil.
    func attrURL(_ name: String) -> URL? {
        HTMLTextExtractor.absoluteURL(from: (try? attr(name)) ?? "")
    }
}

extension String {
    /// Whitespace-trimmed value, or nil when the result is empty.
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// HTML-entity-decoded, whitespace-collapsed, trimmed value.
    var htmlNormalized: String {
        HTMLTextExtractor.decodeHTMLEntities(self)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension URL {
    /// Trimmed, non-blank value of the query item `name`, or nil.
    func queryItemValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value?
            .nilIfBlank
    }
}
