import Foundation

enum YamiboProfileParser {
    static func parse(_ html: String, refreshedAt: Date = .now) throws -> YamiboProfile {
        let document = try KannaSoup.parse(html)
        if isLoginPage(document) {
            throw YamiboError.notAuthenticated
        }

        let username = document.select(".avatar_bg .name").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avatarURL = (document.select(".avatar_m img").first()?.attr("src"))
            .flatMap { normalizedURL(from: $0) }
        let avatarBackgroundURL = avatarBackgroundURL(from: html)

        let creditValues = parseCreditValues(from: document)
        let infoValues = parseInfoValues(from: document)
        let formHash = DiscuzFormHashParser.formHash(in: document, html: html)

        guard !infoValues.uid.isEmpty || !username.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.profile_page"))
        }

        return YamiboProfile(
            uid: infoValues.uid,
            username: username,
            userGroup: infoValues.userGroup,
            points: creditValues.points,
            partner: creditValues.partner,
            totalPoints: creditValues.totalPoints,
            avatarURL: avatarURL,
            avatarBackgroundURL: avatarBackgroundURL,
            formHash: formHash,
            refreshedAt: refreshedAt
        )
    }

    static func isLoginPage(_ html: String) -> Bool {
        guard let document = try? KannaSoup.parse(html) else { return false }
        return isLoginPage(document)
    }

    private static func isLoginPage(_ document: Document) -> Bool {
        if document.select("body.pg_logging").first() != nil {
            return true
        }
        if document.select("input[placeholder=请输入用户名/Email/UID]").first() != nil {
            return true
        }
        let html = document.html()
        return html.localizedCaseInsensitiveContains("action=login")
            || html.localizedCaseInsensitiveContains("id=\"member_login\"")
    }

    private static func parseCreditValues(from document: Document) -> (points: Int, partner: Int, totalPoints: Int) {
        var points = 0
        var partner = 0
        var totalPoints = 0

        let items = document.select(".user_box li").array()
        for item in items {
            let text = item.text()
            let valueText = item.select("span").first()?.text() ?? text
            let value = firstInteger(in: valueText) ?? 0

            if text.contains("总积分") || text.contains("總積分") {
                totalPoints = value
            } else if text.contains("对象") || text.contains("對象") {
                partner = value
            } else if text.contains("积分") || text.contains("積分") {
                points = value
            }
        }

        return (points, partner, totalPoints)
    }

    private static func parseInfoValues(from document: Document) -> (uid: String, userGroup: String) {
        var uid = ""
        var userGroup = ""

        let items = document.select(".myinfo_list li").array()
        for item in items {
            let label = item.ownText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (item.select("span").first()?.text() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if label == "UID" {
                uid = value
            } else if label.contains("用户组") || label.contains("用戶組") {
                userGroup = (item.select("span font").first()?.text() ?? value)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return (uid, userGroup)
    }

    private static func avatarBackgroundURL(from html: String) -> URL? {
        guard let raw = HTMLTextExtractor.firstMatch(
            pattern: #"background-image\s*:\s*url\(([^)]+)\)"#,
            in: html
        )?.dropFirst().first else {
            return nil
        }
        return normalizedURL(from: raw)
    }

    private static func normalizedURL(from value: String) -> URL? {
        let raw = HTMLTextExtractor.decodeHTMLEntities(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .components(separatedBy: "?")
            .first ?? value
        guard !raw.isEmpty else { return nil }
        return HTMLTextExtractor.absoluteURL(from: raw)
    }

    private static func firstInteger(in text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"-?\d+"#, in: text)?.first.flatMap(Int.init)
    }
}
