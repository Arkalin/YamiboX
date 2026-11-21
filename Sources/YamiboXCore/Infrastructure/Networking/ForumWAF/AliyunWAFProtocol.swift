import Foundation

enum AliyunWAFProtocol {
    private static let clearanceName = "acw_sc__v2"

    static func ownsCookie(_ name: String) -> Bool {
        name == clearanceName || ownsSessionCookie(name)
    }

    static func ownsSessionCookie(_ name: String) -> Bool {
        name == "acw_tc" || name == "cdn_sec_tc"
    }

    static func mayContainChallenge(_ response: HTTPURLResponse) -> Bool {
        ((200..<300).contains(response.statusCode) || [403, 405].contains(response.statusCode))
            && ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "")
    }

    static func isChallenge(_ response: HTTPURLResponse, prefix: Data) -> Bool {
        guard mayContainChallenge(response) else { return false }
        let html = String(decoding: prefix.prefix(ForumWAFResponseClassifier.maximumBodyBytes), as: UTF8.self)
        guard html.contains(clearanceName), let document = try? KannaSoup.parse(html) else { return false }
        return document.select("script").contains { script in
            guard !script.hasAttribute("src"),
                  ["", "text/javascript", "application/javascript"].contains(script.attr("type").lowercased()),
                  !script.parents().contains(where: { ["pre", "code", "template", "textarea", "noscript"].contains($0.tagName()) }) else { return false }
            let source = script.ownText()
            return source.range(of: #"^\s*(?:var|let|const)\s+arg1\s*=\s*(['"])[0-9a-fA-F]{40}\1\s*;"#,
                                options: .regularExpression) != nil
                && source.contains("document")
                && source.range(of: #"['"]acw_sc__v2="#, options: .regularExpression) != nil
        }
    }

    static func clearance(in cookies: [YamiboCookie], for url: URL, at date: Date) -> YamiboCookie? {
        cookies.first { isClearance($0, for: url, at: date) }
    }

    static func hasUpdatedClearance(in cookies: [YamiboCookie], for challenge: YamiboWAFChallenge, at date: Date) -> Bool {
        cookies.contains { cookie in
            isClearance(cookie, for: challenge.url, at: date)
                && (cookie.expiresAt?.timeIntervalSince(date) ?? 0) > 60
                && (YamiboWAFChallenge.clearanceFingerprint(for: cookie.value) != challenge.clearanceFingerprint
                    || cookie.expiresAt != challenge.clearanceExpiresAt)
        }
    }

    private static func isClearance(_ cookie: YamiboCookie, for url: URL, at date: Date) -> Bool {
        cookie.name == clearanceName && cookie.matches(url, at: date)
            && cookie.value.range(of: #"\A[0-9a-fA-F]{40}\z"#, options: .regularExpression) != nil
    }

    static func sessionCookies(from response: HTTPURLResponse) -> [YamiboCookie] {
        guard (200..<300).contains(response.statusCode), let url = response.url else { return [] }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { fields, field in
            if let name = field.key as? String, let value = field.value as? String { fields[name] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .map { YamiboCookie($0) }
            .filter { ownsSessionCookie($0.name) && $0.matches(url) }
    }
}
