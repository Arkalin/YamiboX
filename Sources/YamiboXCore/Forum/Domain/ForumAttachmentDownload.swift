import Foundation

public struct ForumAttachmentDownloadRequest: Codable, Sendable {
    public let threadID: String
    public let threadTitle: String
    public let attachment: ForumThreadAttachmentBlock
    public let refererURL: URL

    public init(threadID: String, threadTitle: String, attachment: ForumThreadAttachmentBlock, refererURL: URL) {
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.attachment = attachment
        self.refererURL = refererURL
    }
}

public enum ForumAttachmentEnqueueResult: Sendable {
    case enqueued, alreadyQueued, alreadyDownloaded
}

public protocol ForumAttachmentDownloadStoring: Sendable {
    func enqueueAttachmentDownload(_ request: ForumAttachmentDownloadRequest) async throws -> ForumAttachmentEnqueueResult
    func attachmentDownloadRequest(workID: DownloadWorkID) async throws -> ForumAttachmentDownloadRequest
    func finishAttachmentDownload(workID: DownloadWorkID, file: ForumAttachmentFile) async throws
}
