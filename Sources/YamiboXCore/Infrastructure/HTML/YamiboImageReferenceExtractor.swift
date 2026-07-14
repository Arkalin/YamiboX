import Foundation

/// The forum's image reference rules in one place: which element attributes
/// carry the real image URL in each page template, which references are
/// template noise, and how raw references normalize to absolute URLs.
struct YamiboImageReferenceExtractor: Sendable {
    /// Mobile manga view pages: `zsrc` carries the lazy-loaded original.
    /// Smiley filtering happens at the CSS-selector level in the caller.
    static let mangaPage = Self(attributes: ["zsrc", "src"], rejectedSubstrings: [])
    /// Post image listings reused by reader fallbacks: `static/image/` assets are forum chrome.
    static let forumPostImage = Self(attributes: ["zsrc", "src"], rejectedSubstrings: ["static/image/"])
    /// Forum thread content blocks: `none.gif` is the lazy-load placeholder.
    static let forumContent = Self(attributes: ["file", "zoomfile", "src"], rejectedSubstrings: ["none.gif"])
    /// Novel inline images: `smiley/` assets are emoticons.
    static let novelInline = Self(attributes: ["zoomfile", "file", "src"], rejectedSubstrings: ["smiley/"])

    var attributes: [String]
    var rejectedSubstrings: [String]

    /// Picks the first non-empty attribute in priority order; a chosen value
    /// matching a rejected substring disqualifies the element entirely.
    func rawReference(from element: Element) -> String? {
        for attribute in attributes {
            let value = ((try? element.attr(attribute)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let lowercased = value.lowercased()
            guard !rejectedSubstrings.contains(where: { lowercased.contains($0) }) else {
                return nil
            }
            return value
        }
        return nil
    }

    func url(from element: Element, baseURL: URL = YamiboDomain.baseURL) -> URL? {
        guard let raw = rawReference(from: element) else { return nil }
        return HTMLTextExtractor.absoluteURL(from: raw, baseURL: baseURL)
    }

    static func isEmoticonURL(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains("smiley/")
    }
}
