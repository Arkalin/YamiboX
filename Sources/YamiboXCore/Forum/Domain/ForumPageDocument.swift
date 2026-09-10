import Foundation

public struct ForumPageDocument: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let blocks: [ForumThreadContentBlock]
    public let forms: [ForumForm]
    public let message: String?
    public let continuationURL: URL?
    public let file: ForumAttachmentFile?
    public let uploads: [ForumUploadConfiguration]

    // The response can differ from the requested route, for example a search
    // result, permission message, or a form reached through an unknown link.
    public var purpose: ForumPagePurpose {
        switch forms.first(where: { $0.kind != .standard })?.kind {
        case .thread: return .postEditor
        case .blog: return .blogEditor
        default: return forms.isEmpty ? .document : .actionForm
        }
    }

    public var submissionAccepted: Bool {
        guard forms.isEmpty, let message else { return false }
        let failureMarkers = ["失败", "失敗", "未成功", "不成功", "错误", "錯誤", "抱歉", "无法", "不能", "无权", "没有权限", "无效", "不足", "禁止", "不允许"]
        guard !failureMarkers.contains(where: message.contains) else { return false }
        return ["发表成功", "发布成功", "提交成功", "操作成功", "保存成功", "删除成功", "分享成功", "收藏成功", "已收藏", "已删除好友", "好友已删除", "等待审核", "进入审核", "已保存", "已移除"].contains(where: message.contains)
    }

    public init(
        url: URL, title: String, blocks: [ForumThreadContentBlock] = [],
        forms: [ForumForm] = [], message: String? = nil, continuationURL: URL? = nil,
        file: ForumAttachmentFile? = nil, uploads: [ForumUploadConfiguration] = []
    ) {
        self.url = url
        self.title = title
        self.blocks = blocks
        self.forms = forms
        self.message = message
        self.continuationURL = continuationURL
        self.file = file
        self.uploads = uploads
    }
}

public enum ForumPageError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case confirmationRequired
    case invalidForm
    case requiredField(String)
    case fieldTooLong(String, Int)
    case unsupportedUpload
    case submissionUnconfirmed
    case fileTooLarge
    case uploadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: L10n.string("forum.native.invalid_url")
        case .confirmationRequired: L10n.string("forum.native.confirm_load")
        case .invalidForm: L10n.string("forum.native.invalid_form")
        case let .requiredField(label): L10n.string("forum.native.required_field", label)
        case let .fieldTooLong(label, limit): L10n.string("forum.native.field_too_long", label, limit)
        case .unsupportedUpload: L10n.string("forum.native.upload_unavailable")
        case .submissionUnconfirmed: L10n.string("forum.native.submission_unconfirmed")
        case .fileTooLarge: L10n.string("forum.native.file_too_large")
        case .uploadFailed: L10n.string("forum.native.upload_failed")
        }
    }
}
