import Foundation

struct ForumAttachmentDownloadProcessor: Sendable {
    let store: any ForumAttachmentDownloadStoring
    let client: YamiboClient

    func process(
        _ work: DownloadProcessingWork,
        progress: @escaping @Sendable (DownloadWorkProgress) -> Void
    ) async throws {
        let request = try await store.attachmentDownloadRequest(workID: work.id)
        guard !ForumWebPagePolicy.requiresConfirmationToLoad(request.attachment.url) else {
            throw ForumPageError.confirmationRequired
        }
        let response: ForumPageResponse
        progress(DownloadWorkProgress(phase: .transferring, fraction: 0.05))
        do {
            response = try await ForumPageClient(transport: client).fetchDocument(
                url: request.attachment.url, referer: request.refererURL,
                downloadProgress: { transfer in
                    progress(DownloadWorkProgress(
                        phase: .transferring,
                        fraction: 0.05 + 0.9 * (transfer.fraction ?? 0),
                        receivedBytes: transfer.receivedBytes,
                        hasUnknownLength: transfer.fraction == nil
                    ))
                }
            )
        } catch ForumPageError.fileTooLarge {
            throw AttachmentDownloadError.tooLarge
        }
        try Task.checkCancellation()
        if ForumWebPagePolicy.isLoginPage(response.url) { throw YamiboError.notAuthenticated }
        guard let file = response.file else {
            let page = try ForumFormPageParser.parse(html: response.html, url: response.url)
            throw AttachmentDownloadError.notAFile(page.message.map { String($0.prefix(500)) })
        }
        progress(DownloadWorkProgress(phase: .saving, fraction: 0.95))
        try await store.finishAttachmentDownload(workID: work.id, file: file)
    }
}

private enum AttachmentDownloadError: LocalizedError {
    case notAFile(String?)
    case tooLarge
    var errorDescription: String? {
        switch self {
        case .notAFile(let message): message ?? L10n.string("downloads.attachment.not_file")
        case .tooLarge: L10n.string("downloads.attachment.too_large")
        }
    }
}
