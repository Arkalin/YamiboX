import Foundation

/// Simplified/traditional pairs of the profile info-row labels.
/// Top-level `private` (not nested in the extension) so the same-named groups
/// in the sibling `UserSpaceHTMLParser+…` files stay strictly file-scoped.
private enum Labels {
    static let userGroup = ["用户组", "用戶組"]
    static let totalPoints = ["总积分", "總積分"]
    static let partner = ["对象", "對象"]
}

/// User-space profile page ("home.php?mod=space&uid=…").
extension UserSpaceHTMLParser {
    static func parseProfile(from html: String, uidHint: String? = nil, titleHint: String? = nil) throws -> UserSpaceProfile {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let bodyText = document.body()?.normalizedText() ?? ""

        let uid = uidHint?.nilIfBlank
            ?? firstMatch(#"UID\s*[:：]?\s*(\d+)"#, in: bodyText)
            ?? firstUserID(in: document)
            ?? ""
        let username = firstNonBlank([
            document.firstText(SharedSelectors.userDisplayName),
            titleHint,
            document.title().replacingOccurrences(of: SharedLabels.titleSuffix, with: "")
        ]) ?? L10n.string("user_space.unknown_user")
        let infoRows = parseInfoRows(in: document)

        return UserSpaceProfile(
            uid: uid,
            username: username,
            userGroup: infoRows.first(where: { row in
                Labels.userGroup.contains(where: row.label.contains)
            })?.value,
            avatarURL: document.firstURL(
                anyOf: SharedSelectors.avatarImage,
                attribute: "src"
            ),
            avatarBackgroundURL: document.firstURL(
                anyOf: [
                    ".space_bg img[src]",
                    ".profile_bg img[src]",
                    "img[src*='avatar_big']"
                ],
                attribute: "src"
            ),
            signature: document.firstText(".signature, .sign, .pf_l"),
            totalPoints: intAfterAny(labels: Labels.totalPoints, in: bodyText),
            points: plainPoints(in: bodyText),
            partner: intAfterAny(labels: Labels.partner, in: bodyText),
            infoRows: infoRows
        )
    }

    private static func parseInfoRows(in document: Document) -> [UserSpaceInfoRow] {
        var info: [UserSpaceInfoRow] = []
        var seen = Set<String>()

        for row in document.selectAll("li, tr, .pbm, .pf_l li, .profile_info li") {
            let text = row.normalizedText()
            guard let separator = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let label = String(text[..<separator]).htmlNormalized
            let value = String(text[text.index(after: separator)...]).htmlNormalized
            guard !label.isEmpty, !value.isEmpty else { continue }
            let url = row.firstURL("a[href]")
            let item = UserSpaceInfoRow(label: label, value: value, url: url)
            guard seen.insert(item.id).inserted else { continue }
            info.append(item)
        }

        return info
    }

    /// Plain "积分" (points) value, anchored to a word boundary so it does not
    /// also match inside "总积分" (total points).
    private static func plainPoints(in text: String) -> Int? {
        for pattern in [#"(?:^|\s)积分\s*[:：]?\s*(\d+)"#, #"(?:^|\s)積分\s*[:：]?\s*(\d+)"#] {
            if let value = HTMLTextExtractor.firstMatch(pattern: pattern, in: text)?
                .dropFirst()
                .first
                .flatMap(Int.init) {
                return value
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        HTMLTextExtractor.firstMatch(pattern: pattern, in: text)?
            .dropFirst()
            .first?
            .nilIfBlank
    }
}
