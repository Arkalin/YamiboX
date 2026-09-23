import Foundation

public enum YamiboForumConfigurationError: Error, LocalizedError, Sendable {
    case missingURL
    case duplicateURL
    case invalidURL
    case productionURL

    public var errorDescription: String? {
        switch self {
        case .missingURL: L10n.string("test_forum.missing_url")
        case .duplicateURL: L10n.string("test_forum.duplicate_url")
        case .invalidURL: L10n.string("test_forum.invalid_url")
        case .productionURL: L10n.string("test_forum.production_url")
        }
    }
}

enum YamiboForumLaunchArguments {
    static func resolve(_ arguments: [String]) -> Result<YamiboForumEnvironment, YamiboForumConfigurationError> {
        let flag = "--forum-base-url"
        var values: [String] = []
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                values.append(index + 1 < arguments.count ? arguments[index + 1] : "")
            } else if argument.hasPrefix(flag + "=") {
                values.append(String(argument.dropFirst(flag.count + 1)))
            }
        }
        guard !values.isEmpty else { return .failure(.missingURL) }
        guard values.count == 1 else { return .failure(.duplicateURL) }
        let raw = values[0]
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw, encodingInvalidCharacters: false),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return .failure(.invalidURL) }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !host.contains("%"), !host.contains(where: { $0.isWhitespace }) else { return .failure(.invalidURL) }
        let productionDomain = YamiboForumEnvironment.production.rootDomain
        guard host != productionDomain, !host.hasSuffix(".\(productionDomain)") else { return .failure(.productionURL) }
        components.scheme = scheme
        components.host = host
        components.path = ""
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        guard let normalized = components.url else { return .failure(.invalidURL) }
        return .success(.localSimulator(baseURL: normalized))
    }
}
