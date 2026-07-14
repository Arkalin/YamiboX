import Foundation

public enum YamiboThreadURLCanonicalizer {
    public static func canonicalThreadURL(from url: URL) -> URL {
        let resolvedURL = URL(string: url.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL ?? url.absoluteURL
        let threadID = threadID(from: resolvedURL)

        var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
            ?? URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme ?? YamiboDomain.baseURL.scheme
        components.host = components.host ?? YamiboDomain.baseURL.host
        components.path = "/forum.php"

        var retainedItems: [URLQueryItem] = [.init(name: "mod", value: "viewthread")]
        if let threadID, !threadID.isEmpty {
            retainedItems.append(.init(name: "tid", value: threadID))
        }
        components.queryItems = retainedItems.sorted { $0.name < $1.name }
        return components.url ?? resolvedURL
    }

    public static func canonicalThreadURLKey(for url: URL) -> String {
        canonicalThreadURL(from: url).absoluteString
    }

    public static func threadID(from url: URL) -> String? {
        let resolvedURL = URL(string: url.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL ?? url.absoluteURL
        if let value = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "tid" || $0.name == "ptid" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-\d+-\d+\.html"#, in: resolvedURL.absoluteString)?
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
