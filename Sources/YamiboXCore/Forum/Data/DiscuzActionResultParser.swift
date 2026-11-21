import Foundation

enum DiscuzActionResultParser {
    enum Operation {
        case boardFavorite
        case privateMessage
        case addFriend
        case blacklistAdd
        case blacklistRemove

        private var successMarkers: [String] {
            switch self {
            case .boardFavorite:
                ["已收藏", "已收藏该版块", "收藏成功", "成功收藏", "已經收藏", "信息收藏成功", "資訊收藏成功", "您已收藏"]
            case .privateMessage:
                ["发送成功", "發送成功", "消息发送成功", "訊息發送成功", "消息已发送", "私信已发送", "短消息发送成功"]
            case .addFriend:
                ["好友请求已发送", "好友請求已發送", "好友请求发送成功", "好友請求發送成功", "好友添加成功", "已添加为好友", "你们已成为好友", "你們已成為好友"]
            case .blacklistAdd:
                ["操作成功", "添加成功", "黑名单添加成功", "已加入黑名单", "已加入黑名單", "成功加入黑名单", "成功加入黑名單"]
            case .blacklistRemove:
                ["操作成功", "删除成功", "刪除成功", "黑名单删除成功", "已移出黑名单", "已移出黑名單", "成功移出黑名单", "成功移出黑名單"]
            }
        }

        func confirms(_ notice: String) -> Bool {
            if successMarkers.contains(notice) { return true }
            switch self {
            case .boardFavorite:
                return notice == "抱歉，您已收藏，请勿重复收藏" || notice == "抱歉，您已收藏，請勿重複收藏"
            case .addFriend:
                return (notice.hasPrefix("您已和") && notice.hasSuffix("成为好友"))
                    || (notice.hasPrefix("您已和") && notice.hasSuffix("成為好友"))
            default:
                return false
            }
        }
    }

    private static let messageContainers = ".jump_c, .alert_info, .alert_error, #messagetext, .messagetext, .showmessage"
    private static let loginRequiredMarkers = ["请先登录", "請先登錄", "请登录"]
    private static let failureMarkers = ["失败", "失敗", "错误", "錯誤", "未能", "不成功"]

    static func successMessage(from html: String, operation: Operation) throws -> String {
        let payload = HTMLTextExtractor.discuzAjaxPayload(from: html)
        let body = payload ?? html
        try YamiboHTMLPageInspector.ensureReadable(body)
        guard let document = try? KannaSoup.parse(body, baseURL: YamiboDomain.baseURL.absoluteString) else {
            throw ForumPageError.submissionUnconfirmed
        }
        let visibleBody = YamiboHTMLPageInspector.visibleBody(in: document)
        let messageContainer = document.selectAll(messageContainers)
            .first(where: YamiboHTMLPageInspector.isVisibleNotice)
        let messageElement = messageContainer.flatMap { container in
            container.children().array().first {
                $0.tagName() == "p" && YamiboHTMLPageInspector.isVisibleNotice($0)
            } ?? container
        }
        let message = messageElement.map(YamiboHTMLPageInspector.visibleNoticeText)
            ?? (payload == nil ? visibleBody?.ownText() : visibleBody.map(YamiboHTMLPageInspector.visibleNoticeText))
            ?? ""
        let notice = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if loginRequiredMarkers.contains(where: notice.hasPrefix) {
            throw YamiboError.notAuthenticated
        }
        if failureMarkers.contains(where: notice.contains) {
            throw YamiboError.underlying(notice)
        }
        let sentenceEnd = CharacterSet(charactersIn: "。！!，,；;").union(.whitespacesAndNewlines)
        let firstSentence = notice.components(separatedBy: sentenceEnd).first ?? ""
        let completeNotice = notice.trimmingCharacters(in: sentenceEnd)
        let confirmedPrivateMessage = operation == .privateMessage && completeNotice == "操作成功"
            && (messageContainer != nil || payload != nil)
        guard confirmedPrivateMessage || operation.confirms(completeNotice) || operation.confirms(firstSentence) else {
            throw ForumPageError.submissionUnconfirmed
        }
        return notice
    }
}
