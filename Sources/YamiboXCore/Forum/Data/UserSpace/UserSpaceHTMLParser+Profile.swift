import Foundation

/// Simplified/traditional pairs of the profile labels.
/// Top-level `private` (not nested in the extension) so the same-named groups
/// in the sibling `UserSpaceHTMLParser+…` files stay strictly file-scoped.
private enum Labels {
    static let userGroup = ["用户组", "用戶組"]
    static let totalPoints = ["总积分", "總積分"]
    static let partner = ["对象", "對象"]
    static let points = ["积分", "積分"]
}

/// User-space profile page ("home.php?mod=space&do=profile&…", touch template
/// `space_profile.htm`). Verified against the live template markup:
/// - identity:  `.avatar_bg` holds `.avatar_m img` and `<h2 class="name">`
/// - credits:   `.user_box li` = `<span>VALUE UNIT</span>LABEL` — the value
///   `<span>` comes BEFORE the label text, so credits must be read from the
///   span, never as "label followed by number" running text
/// - info rows: `.myinfo_list li` = `LABEL<span>VALUE</span>` — no colon
///   separator between label and value
/// - background: emitted as a `background-image:url(…)` inline style
extension UserSpaceHTMLParser {
    static func parseProfile(from html: String, uidHint: String? = nil, titleHint: String? = nil) throws -> UserSpaceProfile {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)

        let infoRows = parseInfoRows(in: document)
        let credits = parseCredits(in: document)
        let uid = uidHint?.nilIfBlank
            ?? infoRows.first(where: { $0.label == "UID" })?.value.nilIfBlank
            ?? firstMatch(#"UID\s*[:：]?\s*(\d+)"#, in: document.body()?.normalizedText() ?? "")
            ?? firstUserID(in: document)
            ?? ""
        let username = firstNonBlank([
            document.firstText(".avatar_bg .name"),
            titleHint,
            document.title().replacingOccurrences(of: SharedLabels.titleSuffix, with: "")
        ]) ?? L10n.string("user_space.unknown_user")

        return UserSpaceProfile(
            uid: uid,
            username: username,
            userGroup: infoRows.first(where: { row in
                Labels.userGroup.contains(where: row.label.contains)
            })?.value,
            avatarURL: document.firstURL(
                anyOf: [".avatar_m img[src]"] + SharedSelectors.avatarImage,
                attribute: "src"
            ),
            avatarBackgroundURL: avatarBackgroundURL(in: document, html: html),
            signature: document.firstText(".myinfo_list .sig, .signature, .sign"),
            totalPoints: credits.totalPoints,
            points: credits.points,
            partner: credits.partner,
            infoRows: infoRows
        )
    }

    /// Credit values from `.user_box li`. The row's `<span>` holds the value
    /// ("55990 点") and the credit name is the text outside it, so extraction
    /// stays independent of their order. "总积分" is matched before "积分"
    /// because the former contains the latter.
    private static func parseCredits(in document: Document) -> (totalPoints: Int?, points: Int?, partner: Int?) {
        var totalPoints: Int?
        var points: Int?
        var partner: Int?

        for item in document.selectAll(".user_box li") {
            guard let valueText = item.selectFirst("span")?.normalizedText(),
                  let value = HTMLTextExtractor.firstMatch(pattern: #"-?\d+"#, in: valueText)?
                      .first
                      .flatMap(Int.init) else {
                continue
            }
            let text = item.normalizedText()
            if Labels.totalPoints.contains(where: text.contains) {
                totalPoints = value
            } else if Labels.partner.contains(where: text.contains) {
                partner = value
            } else if Labels.points.contains(where: text.contains) {
                points = value
            }
        }

        return (totalPoints, points, partner)
    }

    private static func parseInfoRows(in document: Document) -> [UserSpaceInfoRow] {
        var info: [UserSpaceInfoRow] = []
        var seen = Set<String>()

        for row in document.selectAll(".myinfo_list li") {
            let label = row.ownText().htmlNormalized
            let value = row.selectFirst("span")?.normalizedText().htmlNormalized ?? ""
            guard !label.isEmpty, !value.isEmpty else { continue }
            let url = row.firstURL("a[href]")
            let item = UserSpaceInfoRow(label: label, value: value, url: url)
            guard seen.insert(item.id).inserted else { continue }
            info.append(item)
        }

        return info
    }

    private static func avatarBackgroundURL(in document: Document, html: String) -> URL? {
        if let raw = HTMLTextExtractor.firstMatch(pattern: #"background-image\s*:\s*url\(([^)]+)\)"#, in: html)?
            .dropFirst()
            .first {
            let cleaned = HTMLTextExtractor.decodeHTMLEntities(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let url = HTMLTextExtractor.absoluteURL(from: cleaned) {
                return url
            }
        }
        return document.firstURL(
            anyOf: [
                ".space_bg img[src]",
                ".profile_bg img[src]",
                "img[src*='avatar_big']"
            ],
            attribute: "src"
        )
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: pattern, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }
}
