import Foundation

extension Element {
    func selectAll(_ selector: String) -> [Element] {
        select(selector).array()
    }

    func selectFirst(_ selector: String) -> Element? {
        select(selector).first()
    }

    func selectFirst(anyOf selectors: [String]) -> Element? {
        for selector in selectors {
            if let element = selectFirst(selector) {
                return element
            }
        }
        return nil
    }

    func firstText(_ selector: String) -> String? {
        selectFirst(selector)?.normalizedText().nilIfBlank
    }

    func firstText(anyOf selectors: [String]) -> String? {
        for selector in selectors {
            if let text = firstText(selector) {
                return text
            }
        }
        return nil
    }

    func firstURL(_ selector: String, attribute: String = "href") -> URL? {
        selectFirst(selector)?.attrURL(attribute)
    }

    func firstURL(anyOf selectors: [String], attribute: String = "href") -> URL? {
        for selector in selectors {
            if let url = firstURL(selector, attribute: attribute) {
                return url
            }
        }
        return nil
    }

    func normalizedText() -> String {
        text().htmlNormalized
    }

    func attrText(_ name: String) -> String? {
        attr(name).nilIfBlank
    }

    func attrURL(_ name: String) -> URL? {
        HTMLTextExtractor.absoluteURL(from: attr(name))
    }
}

extension String {
    var htmlNormalized: String {
        HTMLTextExtractor.decodeHTMLEntities(self)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension URL {
    func queryItemValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value?
            .nilIfBlank
    }
}
