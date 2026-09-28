import Foundation

/// Feature-facing I/O capabilities shared by assembly and presentation.
public protocol ForumHomePageLoading: Sendable {
    func cachedForumHome(allowExpired: Bool) async -> ForumHomePage?
    func fetchForumHome(preferCache: Bool) async throws -> ForumHomePage
}

public protocol ForumBoardPageLoading: Sendable {
    func cachedForumBoard(
        fid: String,
        page: Int,
        filterID: String?,
        orderFilter: String?,
        orderBy: String?,
        allowExpired: Bool
    ) async -> ForumBoardPage?

    func fetchForumBoard(
        fid: String,
        title: String?,
        page: Int,
        filterID: String?,
        orderFilter: String?,
        orderBy: String?,
        preferCache: Bool
    ) async throws -> ForumBoardPage

    func addBoardFavorite(fid: String, formHash: String?) async throws -> String
}

public protocol ForumSearchPageLoading: Sendable {
    func searchForum(query: String, forumID: String?, formHash: String?) async throws -> ForumSearchPage
    func searchForumPage(query: String, searchID: String, page: Int) async throws -> ForumSearchPage
}

public protocol ForumPageLoading: Sendable {
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment
}

public protocol ForumComposerDraftPersisting: Sendable {
    func generation() async throws -> UUID
    func drafts(accountUID: String) async throws -> [ForumComposerDraft]
    func save(_ draft: ForumComposerDraft, expecting revision: Int64?, generation: UUID) async throws
    func delete(id: UUID, accountUID: String, expecting revision: Int64?, generation: UUID) async throws -> Bool
    func importResource(_ file: ForumAttachmentFile, draftID: UUID, accountUID: String, generation: UUID) async throws -> UUID
    func resource(id: UUID, accountUID: String) async throws -> ForumAttachmentFile
    func removeUnreferencedResources(draftID: UUID, accountUID: String, generation: UUID) async throws
}
