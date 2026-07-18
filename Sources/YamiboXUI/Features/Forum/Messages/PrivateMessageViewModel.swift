import Foundation
import Observation
import YamiboXCore

protocol PrivateMessagePageLoading: Sendable {
    func fetchPrivateMessagePage(uid: String, page: Int?, titleHint: String?) async throws -> PrivateMessagePage
    func sendPrivateMessage(privateMessageID: String, uid: String, formHash: String, message: String) async throws -> String
}

extension UserSpaceRepository: PrivateMessagePageLoading {}

@MainActor
@Observable
final class PrivateMessageViewModel {
    var page: PrivateMessagePage?
    var currentProfile: YamiboProfile?
    var inputText = ""
    var currentPage = 1
    var isLoading = false
    var isSending = false
    var errorMessage: String?
    var sendResultMessage: String?

    let uid: String
    let titleHint: String?

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any PrivateMessagePageLoading
    @ObservationIgnored private let currentProfileProvider: @Sendable () async -> YamiboProfile?

    init(uid: String, titleHint: String?, dependencies: ForumDependencies) {
        self.uid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        repositoryProvider = {
            await dependencies.makeUserSpaceRepository()
        }
        currentProfileProvider = {
            await dependencies.profileStore.load()
        }
    }

    init(
        uid: String,
        titleHint: String?,
        currentProfile: YamiboProfile? = nil,
        repository: any PrivateMessagePageLoading
    ) {
        self.uid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
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
        page?.title ?? titleHint ?? L10n.string("private_message.title")
    }

    var pageNavigation: ForumPageNavigation? {
        page?.pageNavigation
    }

    var canSend: Bool {
        page != nil && !isSending && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        if currentProfile == nil {
            currentProfile = await currentProfileProvider()
        }
        guard page == nil else { return }
        await loadPage(nil)
    }

    func refresh() async {
        await loadPage(nil)
    }

    func goToPage(_ page: Int) async {
        await loadPage(max(1, page))
    }

    func send() async {
        guard let page else { return }
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard let formHash = page.formHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? currentProfile?.formHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            errorMessage = L10n.string("private_message.send_requires_login")
            return
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let repository = await repositoryProvider()
            sendResultMessage = try await repository.sendPrivateMessage(
                privateMessageID: page.privateMessageID,
                uid: uid,
                formHash: formHash,
                message: message
            )
            inputText = ""
            await loadPage(currentPage)
        } catch {
            errorMessage = L10n.string("private_message.send_failed", error.localizedDescription)
        }
    }

    func clearSendResult() {
        sendResultMessage = nil
    }

    private func loadPage(_ requestedPage: Int?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let repository = await repositoryProvider()
            let loadedPage = try await repository.fetchPrivateMessagePage(
                uid: uid,
                page: requestedPage,
                titleHint: titleHint
            )
            page = loadedPage
            currentPage = loadedPage.pageNavigation?.currentPage ?? requestedPage ?? 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
