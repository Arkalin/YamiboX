import Foundation

/// The one canonical success/failure sniffer for Discuz "action result" pages
/// (add friend, send private message, favorite a board, ...).
///
/// Discuz answers these form posts with a small jump/notice page whose only
/// machine-readable signal is its human-readable copy. Three parsers used to
/// re-implement the sniffing with drifting marker sets and precedence
/// (`UserSpaceHTMLParser.parseAddFriendResult`, `.parsePrivateMessageSendResult`,
/// `ForumHTMLParser.parseBoardFavoriteResult`); this type is the behavioral union
/// of those copies, and the copies now delegate here.
///
/// Classification precedence (the order is the contract):
/// 1. login-required markers → `YamiboError.notAuthenticated`
/// 2. explicit success markers → success
/// 3. generic failure markers → failure
/// 4. empty page → failure (nothing to classify)
/// 5. anything else → success (Discuz prints a plain confirmation sentence)
///
/// Success markers are deliberately checked BEFORE the failure blacklist:
/// the blacklist words ("失败"/"错误") are generic enough to appear inside a
/// genuine success message (e.g. a success page that echoes "0 次失败" or quotes
/// an earlier error), while the success markers are specific phrases failure
/// pages never produce. One of the merged copies had the opposite order and
/// would misclassify such pages as failures.
enum DiscuzActionResultParser {
    /// Discuz notice containers, most specific first. `body` is intentionally
    /// NOT part of this list: selection returns matches in document order, so an
    /// always-present ancestor like `body` would win over every scoped container
    /// (two of the three merged copies appended ", body" to the selector and
    /// thereby always sniffed the whole page text). The body text is only the
    /// fallback when no scoped container exists.
    /// `#messagetext` is the ajax showmessage node (it carries an id, not a class).
    private static let messageContainers = ".jump_c, .alert_info, #messagetext, .messagetext, .showmessage, .wp"

    private static let loginRequiredMarkers = ["请先登录", "請先登錄", "请登录"]
    private static let successMarkers = ["已收藏", "收藏成功", "成功收藏"]
    private static let failureMarkers = ["失败", "失敗", "错误", "錯誤"]

    /// Result-page sniffing that returns the server's own message on success.
    ///
    /// Failure surfaces the server message (`YamiboError.underlying`); an empty
    /// page throws `parsingFailed` with `emptyPageContext`.
    static func successMessage(from html: String, emptyPageContext context: String) throws -> String {
        try successMessage(
            from: html,
            failure: { YamiboError.underlying($0) },
            empty: { YamiboError.parsingFailed(context: context) },
            success: { message, _ in message }
        )
    }

    /// Result-page sniffing for callers with a fixed failure error and a
    /// localized default success message.
    ///
    /// A page carrying an explicit success marker returns the server's message;
    /// an unrecognized-but-non-empty page returns `fallbackSuccessMessage`;
    /// failure and empty pages throw `failureError`.
    static func successMessage(
        from html: String,
        failureError: Error,
        fallbackSuccessMessage: String
    ) throws -> String {
        try successMessage(
            from: html,
            failure: { _ in failureError },
            empty: { failureError },
            success: { message, hitSuccessMarker in hitSuccessMarker ? message : fallbackSuccessMessage }
        )
    }

    private static func successMessage(
        from html: String,
        failure: (String) -> Error,
        empty: () -> Error,
        success: (_ message: String, _ hitSuccessMarker: Bool) -> String
    ) throws -> String {
        try YamiboHTMLPageInspector.ensureReadable(html)
        // inajax responses arrive as `<root><![CDATA[…]]></root>` — parse the
        // payload, or the parser mangles the first tag and leaks a "]]>".
        let body = HTMLTextExtractor.discuzAjaxPayload(from: html) ?? html
        let document = try KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString)
        let message = document.selectFirst(messageContainers)?.normalizedText()
            ?? document.body()?.normalizedText()
            ?? ""

        if loginRequiredMarkers.contains(where: message.contains) {
            throw YamiboError.notAuthenticated
        }
        if successMarkers.contains(where: message.contains) {
            return success(message, true)
        }
        if failureMarkers.contains(where: message.contains) {
            throw failure(message)
        }
        if message.isEmpty {
            throw empty()
        }
        return success(message, false)
    }
}
