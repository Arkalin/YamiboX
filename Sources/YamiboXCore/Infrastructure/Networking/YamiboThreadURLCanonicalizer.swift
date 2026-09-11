import Foundation

public enum YamiboThreadURLCanonicalizer {
    public static func canonicalThreadURL(from url: URL) -> URL {
        let resolvedURL = URL(string: url.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL ?? url.absoluteURL
        guard let threadID = threadID(from: resolvedURL) else { return resolvedURL }

        var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
            ?? URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme ?? YamiboDomain.baseURL.scheme
        components.host = components.host ?? YamiboDomain.baseURL.host
        components.path = "/forum.php"

        var retainedItems: [URLQueryItem] = [.init(name: "mod", value: "viewthread")]
        retainedItems.append(.init(name: "tid", value: threadID))
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
           !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), Int(value).map({ $0 > 0 }) == true {
            return value
        }

        return HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-\d+-\d+\.html"#, in: resolvedURL.absoluteString)?
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
