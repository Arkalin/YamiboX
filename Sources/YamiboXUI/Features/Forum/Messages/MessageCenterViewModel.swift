import Foundation
import Observation
import YamiboXCore

protocol MessageCenterPageLoading: Sendable {
    func fetchPrivateMessages(page: Int) async throws -> UserSpacePrivateMessagePage
    func fetchNotices(page: Int) async throws -> UserSpaceNoticePage
}

extension UserSpaceRepository: MessageCenterPageLoading {}

@MainActor
@Observable
final class MessageCenterViewModel {
    enum Content: Equatable {
        case privateMessages(UserSpacePrivateMessagePage)
        case notices(UserSpaceNoticePage)
    }

    var selectedTab: MessageCenterTab
    var content: Content?
    var currentPage = 1
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any MessageCenterPageLoading
    @ObservationIgnored private var generation = 0

    init(initialTab: MessageCenterTab = .privateMessages, dependencies: ForumDependencies) {
        selectedTab = initialTab
        repositoryProvider = {
            await dependencies.makeUserSpaceRepository()
        }
    }

    init(initialTab: MessageCenterTab = .privateMessages, repository: any MessageCenterPageLoading) {
        selectedTab = initialTab
        repositoryProvider = {
            repository
        }
    }

    var navigationTitle: String {
        Self.title(for: selectedTab)
    }

    var pageNavigation: ForumPageNavigation? {
        switch content {
        case let .privateMessages(page):
            page.pageNavigation
        case let .notices(page):
            page.pageNavigation
        case nil:
            nil
        }
    }

    func load() async {
        guard content == nil else { return }
        await loadSelectedTab(page: currentPage)
    }

    func refresh() async {
        await loadSelectedTab(page: currentPage)
    }

    func selectTab(_ tab: MessageCenterTab) async {
        guard tab != selectedTab else { return }
        selectedTab = tab
        currentPage = 1
        content = nil
        errorMessage = nil
        await loadSelectedTab(page: 1)
    }

    func goToPage(_ page: Int) async {
        let nextPage = max(1, page)
        guard nextPage != currentPage else { return }
        await loadSelectedTab(page: nextPage)
    }

    static func title(for tab: MessageCenterTab) -> String {
        switch tab {
        case .privateMessages:
            L10n.string("message_center.private_messages")
        case .notices:
            L10n.string("message_center.notices")
        }
    }

    private func loadSelectedTab(page: Int) async {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }

        do {
            let repository = await repositoryProvider()
            let loadedContent: Content
            switch selectedTab {
            case .privateMessages:
                loadedContent = .privateMessages(try await repository.fetchPrivateMessages(page: page))
            case .notices:
                loadedContent = .notices(try await repository.fetchNotices(page: page))
            }
            guard requestGeneration == generation else { return }
            content = loadedContent
            currentPage = pageNavigation?.currentPage ?? page
        } catch {
            guard requestGeneration == generation else { return }
            content = nil
            currentPage = page
            errorMessage = error.localizedDescription
        }
    }
}
