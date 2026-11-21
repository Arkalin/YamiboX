import Foundation

enum DiscuzActionResultParser {
    private static let messageContainers = ".jump_c, .alert_info, #messagetext, .messagetext, .showmessage, .wp"

    private static let loginRequiredMarkers = ["请先登录", "請先登錄", "请登录"]
    private static let successMarkers = ["已收藏", "收藏成功", "成功收藏"]
    private static let failureMarkers = ["失败", "失敗", "错误", "錯誤"]

    static func successMessage(from html: String, emptyPageContext context: String) throws -> String {
        try successMessage(
            from: html,
            failure: { YamiboError.underlying($0) },
            empty: { YamiboError.parsingFailed(context: context) },
            success: { message, _ in message }
        )
    }

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
