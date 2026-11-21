import Foundation

struct YamiboImageReferenceExtractor: Sendable {
    static let mangaPage = Self(attributes: ["zsrc", "src"], rejectedSubstrings: [])
    static let forumPostImage = Self(attributes: ["zsrc", "src"], rejectedSubstrings: ["static/image/"])
    static let forumContent = Self(attributes: ["file", "zoomfile", "src"], rejectedSubstrings: ["none.gif"])
    static let novelInline = Self(attributes: ["zoomfile", "file", "src"], rejectedSubstrings: ["smiley/"])

    var attributes: [String]
    var rejectedSubstrings: [String]

    func rawReference(from element: Element) -> String? {
        for attribute in attributes {
            let value = element.attr(attribute)
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
