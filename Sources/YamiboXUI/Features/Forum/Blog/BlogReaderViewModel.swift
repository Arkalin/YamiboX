import Foundation
import Observation
import YamiboXCore

protocol BlogReaderPageLoading: Sendable {
    func fetchBlogPage(blogID: String, uid: String?, page: Int) async throws -> BlogReaderPage
    func postBlogComment(blogID: String, uid: String, message: String, formHash: String) async throws -> String
}

extension BlogReaderRepository: BlogReaderPageLoading {}

@MainActor
@Observable
final class BlogReaderViewModel {
    var page: BlogReaderPage?
    var currentProfile: YamiboProfile?
    var commentText = ""
    var currentPage = 1
    var isLoading = false
    var isSubmittingComment = false
    var errorMessage: String?
    var commentResultMessage: String?

    let blogID: String
    let uid: String?
    let titleHint: String?

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any BlogReaderPageLoading
    @ObservationIgnored private let currentProfileProvider: @Sendable () async -> YamiboProfile?

    init(blogID: String, uid: String?, titleHint: String?, dependencies: ForumDependencies) {
        self.blogID = blogID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.uid = uid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        repositoryProvider = {
            await dependencies.makeBlogReaderRepository()
        }
        currentProfileProvider = {
            await dependencies.profileStore.load()
        }
    }

    init(
        blogID: String,
        uid: String?,
        titleHint: String?,
        currentProfile: YamiboProfile? = nil,
        repository: any BlogReaderPageLoading
    ) {
        self.blogID = blogID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.uid = uid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.currentProfile = currentProfile
        repositoryProvider = {
            repository
        }
        currentProfileProvider = {
            currentProfile
        }
    }

    var navigationTitle: String {
        page?.title ?? titleHint ?? L10n.string("blog_reader.title")
    }

    var pageNavigation: ForumPageNavigation? {
        page?.pageNavigation
    }

    var canSubmitComment: Bool {
        page != nil
            && !isSubmittingComment
            && canEditComment
            && !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canEditComment: Bool {
        currentProfile?.formHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
            && !isSubmittingComment
    }

    var commentPlaceholder: String {
        if currentProfile?.formHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty == nil {
            return L10n.string("blog_reader.comment_requires_login")
        }
        return L10n.string("blog_reader.comment_placeholder")
    }

    func load() async {
        if currentProfile == nil {
            currentProfile = await currentProfileProvider()
        }
        guard page == nil else { return }
        await loadPage(1)
    }

    func refresh() async {
        await loadPage(currentPage)
    }

    func goToPage(_ page: Int) async {
        let nextPage = max(1, page)
        guard nextPage != currentPage else { return }
        await loadPage(nextPage)
    }

    func submitComment() async {
        guard let page else { return }
        let message = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            errorMessage = L10n.string("blog_reader.comment_empty")
            return
        }
        guard let authorUID = page.author.uid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            errorMessage = L10n.string("blog_reader.comment_failed", L10n.string("user_space.unknown_user"))
            return
        }
        guard let formHash = currentProfile?.formHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            errorMessage = L10n.string("blog_reader.comment_requires_login")
            return
        }

        isSubmittingComment = true
        errorMessage = nil
        defer { isSubmittingComment = false }

        do {
            let repository = await repositoryProvider()
            commentResultMessage = try await repository.postBlogComment(
                blogID: blogID,
                uid: authorUID,
                message: message,
                formHash: formHash
            )
            commentText = ""
            await loadPage(currentPage)
        } catch {
            errorMessage = L10n.string("blog_reader.comment_failed", error.localizedDescription)
        }
    }

    func clearCommentResult() {
        commentResultMessage = nil
    }

    private func loadPage(_ page: Int) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let repository = await repositoryProvider()
            let loaded = try await repository.fetchBlogPage(blogID: blogID, uid: uid, page: page)
            self.page = loaded
            currentPage = loaded.pageNavigation?.currentPage ?? page
        } catch {
            self.page = nil
            currentPage = page
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
