import Foundation
import Observation
import YamiboXCore

protocol UserSpacePageLoading: Sendable {
    func fetchProfile(uid: String?, titleHint: String?) async throws -> UserSpaceProfile
    func fetchThreads(uid: String?, page: Int) async throws -> UserSpaceThreadPage
    func fetchReplies(uid: String?, page: Int) async throws -> UserSpaceReplyPage
    func fetchBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage
    func fetchMyBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage
    func fetchFriendBlogs(page: Int) async throws -> UserSpaceBlogPage
    func fetchViewAllBlogs(filter: UserSpaceViewAllBlogFilter, page: Int) async throws -> UserSpaceBlogPage
    func fetchFriendPage(type: UserSpaceFriendType, page: Int) async throws -> UserSpaceFriendPage
    func fetchAddFriendForm(uid: String, nameHint: String?) async throws -> UserSpaceAddFriendForm
    func addFriend(uid: String, formHash: String, note: String, groupID: Int) async throws -> String
}

extension UserSpaceRepository: UserSpacePageLoading {}

@MainActor
@Observable
final class UserSpaceViewModel {
    enum Content: Equatable {
        case threads(UserSpaceThreadPage)
        case replies(UserSpaceReplyPage)
        case blogs(UserSpaceBlogPage)
        case friends(UserSpaceFriendPage)
    }

    var profile: UserSpaceProfile?
    var selectedSection: UserSpaceSection = .space
    var selectedSubPage: UserSpaceSubPage = .profile
    var viewAllBlogFilter: UserSpaceViewAllBlogFilter = .latest
    var content: Content?
    var currentPage = 1
    var isLoadingProfile = false
    var isLoadingContent = false
    var addFriendTargetUID: String?
    var addFriendTargetName: String?
    var addFriendForm: UserSpaceAddFriendForm?
    var isLoadingAddFriendForm = false
    var isSubmittingAddFriend = false
    var addFriendErrorMessage: String?
    var addFriendResultMessage: String?
    var errorMessage: String?

    let uid: String?
    let titleHint: String?
    var isSelf: Bool

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any UserSpacePageLoading
    @ObservationIgnored private let accountUIDProvider: @Sendable () async -> String?
    /// Independent generations for the two state axes this view model writes:
    /// `profile` vs `content`/`currentPage`. A shared counter would let a
    /// sub-page switch turn a still-relevant in-flight profile response
    /// stale (and vice versa) even though the two never conflict.
    @ObservationIgnored private var profileGeneration = 0
    @ObservationIgnored private var contentGeneration = 0

    init(
        uid: String?,
        titleHint: String?,
        initialSection: UserSpaceSection = .space,
        initialSubPage: UserSpaceSubPage = .profile,
        dependencies: ForumDependencies
    ) {
        self.uid = uid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let initialIsSelf = self.uid == nil
        self.isSelf = initialIsSelf
        selectedSection = initialSection
        selectedSubPage = initialSubPage.section == initialSection ? initialSubPage : Self.subPages(for: initialSection, isSelf: initialIsSelf).first ?? .profile
        repositoryProvider = {
            await dependencies.makeUserSpaceRepository()
        }
        accountUIDProvider = {
            let session = await dependencies.sessionStore.load()
            if let accountUID = session.accountUID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return accountUID
            }
            let profile = await dependencies.profileStore.load()
            return profile?.uid.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    init(
        uid: String?,
        titleHint: String?,
        initialSection: UserSpaceSection = .space,
        initialSubPage: UserSpaceSubPage = .profile,
        isSelf: Bool? = nil,
        currentAccountUID: String? = nil,
        repository: any UserSpacePageLoading
    ) {
        self.uid = uid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedAccountUID = currentAccountUID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let initialIsSelf = isSelf ?? Self.resolvedIsSelf(uid: self.uid, accountUID: normalizedAccountUID)
        self.isSelf = initialIsSelf
        selectedSection = initialSection
        selectedSubPage = initialSubPage.section == initialSection ? initialSubPage : Self.subPages(for: initialSection, isSelf: initialIsSelf).first ?? .profile
        repositoryProvider = {
            repository
        }
        accountUIDProvider = {
            normalizedAccountUID
        }
    }

    var navigationTitle: String {
        let name = profile?.username.nilIfEmpty ?? titleHint ?? L10n.string("user_space.unknown_user")
        switch selectedSection {
        case .space:
            return isSelf ? L10n.string("user_space.my_profile") : L10n.string("user_space.other_profile_title", name)
        case .threads:
            return isSelf ? L10n.string("user_space.my_threads") : L10n.string("user_space.other_threads_title", name)
        case .blogs:
            return isSelf ? L10n.string("user_space.my_blogs") : L10n.string("user_space.other_blogs_title", name)
        case .friends:
            return Self.title(for: selectedSubPage, isSelf: isSelf)
        }
    }

    var availableSections: [UserSpaceSection] {
        UserSpaceSection.allCases
    }

    var availableSubPages: [UserSpaceSubPage] {
        Self.subPages(for: selectedSection, isSelf: isSelf)
    }

    var pageNavigation: ForumPageNavigation? {
        switch content {
        case let .threads(page):
            page.pageNavigation
        case let .replies(page):
            page.pageNavigation
        case let .blogs(page):
            page.pageNavigation
        case let .friends(page):
            page.pageNavigation
        case nil:
            nil
        }
    }

    var canOpenBlogEditor: Bool {
        isSelf && selectedSection == .blogs
    }

    var isAddFriendSheetPresented: Bool {
        addFriendTargetUID != nil
    }

    func load() async {
        await resolveIsSelf()
        if profile == nil {
            await loadProfile()
        }
        guard selectedSubPage != .profile else { return }
        await loadSelectedSubPage(page: currentPage)
    }

    func refresh() async {
        if selectedSubPage == .profile {
            await loadProfile()
        } else {
            await loadSelectedSubPage(page: currentPage)
        }
    }

    func selectSection(_ section: UserSpaceSection) async {
        guard section != selectedSection else { return }
        selectedSection = section
        let subPage = Self.subPages(for: section, isSelf: isSelf).first ?? .profile
        await selectSubPage(subPage)
    }

    func selectTab(_ tab: UserSpaceSubPage) async {
        await selectSubPage(tab)
    }

    func selectSubPage(_ subPage: UserSpaceSubPage) async {
        guard subPage != selectedSubPage else { return }
        // The switch itself rewrites the content axis, so it must invalidate
        // any in-flight content request even when no new request follows
        // (switching to an already-cached profile) — and then also clear the
        // spinner that doomed request can no longer clear.
        contentGeneration += 1
        isLoadingContent = false
        selectedSubPage = subPage
        selectedSection = subPage.section
        currentPage = 1
        errorMessage = nil
        content = nil
        if subPage == .profile {
            if profile == nil {
                await loadProfile()
            }
        } else {
            await loadSelectedSubPage(page: 1)
        }
    }

    func selectViewAllBlogFilter(_ filter: UserSpaceViewAllBlogFilter) async {
        guard filter != viewAllBlogFilter else { return }
        viewAllBlogFilter = filter
        guard selectedSubPage == .viewAllBlogs else { return }
        currentPage = 1
        content = nil
        await loadSelectedSubPage(page: 1)
    }

    func goToPage(_ page: Int) async {
        guard selectedSubPage != .profile else { return }
        let nextPage = max(1, page)
        guard nextPage != currentPage else { return }
        await loadSelectedSubPage(page: nextPage)
    }

    func beginAddFriend() async {
        guard !isSelf, let targetUID = profile?.uid.nilIfEmpty else { return }
        addFriendTargetUID = targetUID
        addFriendTargetName = profile?.username
        addFriendForm = nil
        addFriendErrorMessage = nil
        isLoadingAddFriendForm = true
        defer { isLoadingAddFriendForm = false }

        do {
            let repository = await repositoryProvider()
            addFriendForm = try await repository.fetchAddFriendForm(uid: targetUID, nameHint: profile?.username)
        } catch {
            addFriendErrorMessage = error.localizedDescription
        }
    }

    func retryAddFriendForm() async {
        guard let uid = addFriendTargetUID else { return }
        addFriendForm = nil
        addFriendErrorMessage = nil
        isLoadingAddFriendForm = true
        defer { isLoadingAddFriendForm = false }

        do {
            let repository = await repositoryProvider()
            addFriendForm = try await repository.fetchAddFriendForm(uid: uid, nameHint: addFriendTargetName)
        } catch {
            addFriendErrorMessage = error.localizedDescription
        }
    }

    func submitAddFriend(note: String, groupID: Int) async {
        guard let uid = addFriendTargetUID, let form = addFriendForm else { return }
        isSubmittingAddFriend = true
        addFriendErrorMessage = nil
        defer { isSubmittingAddFriend = false }

        do {
            let repository = await repositoryProvider()
            addFriendResultMessage = try await repository.addFriend(
                uid: uid,
                formHash: form.formHash,
                note: note,
                groupID: groupID
            )
            isSubmittingAddFriend = false
            dismissAddFriend()
        } catch {
            addFriendErrorMessage = error.localizedDescription
        }
    }

    func dismissAddFriend() {
        guard !isSubmittingAddFriend else { return }
        addFriendTargetUID = nil
        addFriendTargetName = nil
        addFriendForm = nil
        addFriendErrorMessage = nil
        isLoadingAddFriendForm = false
    }

    func clearAddFriendResult() {
        addFriendResultMessage = nil
    }

    private func loadProfile() async {
        profileGeneration += 1
        let requestGeneration = profileGeneration
        isLoadingProfile = true
        errorMessage = nil
        defer {
            if requestGeneration == profileGeneration {
                isLoadingProfile = false
            }
        }

        do {
            let repository = await repositoryProvider()
            let loadedProfile = try await repository.fetchProfile(uid: uid, titleHint: titleHint)
            guard requestGeneration == profileGeneration else { return }
            profile = loadedProfile
        } catch {
            guard requestGeneration == profileGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedSubPage(page: Int) async {
        contentGeneration += 1
        let requestGeneration = contentGeneration
        isLoadingContent = true
        errorMessage = nil
        defer {
            if requestGeneration == contentGeneration {
                isLoadingContent = false
            }
        }

        do {
            let repository = await repositoryProvider()
            let loadedContent: Content?
            switch selectedSubPage {
            case .profile:
                loadedContent = content
            case .threads:
                loadedContent = .threads(try await repository.fetchThreads(uid: uid, page: page))
            case .replies:
                loadedContent = .replies(try await repository.fetchReplies(uid: uid, page: page))
            case .myBlogs:
                loadedContent = .blogs(try await repository.fetchMyBlogs(uid: uid, page: page))
            case .friendBlogs:
                loadedContent = .blogs(try await repository.fetchFriendBlogs(page: page))
            case .viewAllBlogs:
                loadedContent = .blogs(try await repository.fetchViewAllBlogs(filter: viewAllBlogFilter, page: page))
            case .friends:
                loadedContent = .friends(try await repository.fetchFriendPage(type: .myFriend, page: page))
            case .online:
                loadedContent = .friends(try await repository.fetchFriendPage(type: .onlineMember, page: page))
            case .visitors:
                loadedContent = .friends(try await repository.fetchFriendPage(type: .myVisitor, page: page))
            case .traces:
                loadedContent = .friends(try await repository.fetchFriendPage(type: .myTrace, page: page))
            }
            guard requestGeneration == contentGeneration else { return }
            content = loadedContent
            currentPage = pageNavigation?.currentPage ?? page
        } catch {
            guard requestGeneration == contentGeneration else { return }
            content = nil
            currentPage = page
            errorMessage = error.localizedDescription
        }
    }

    static func subPages(for section: UserSpaceSection, isSelf: Bool) -> [UserSpaceSubPage] {
        switch section {
        case .space:
            [.profile]
        case .threads:
            [.threads, .replies]
        case .blogs:
            isSelf ? [.friendBlogs, .myBlogs, .viewAllBlogs] : [.myBlogs]
        case .friends:
            [.friends, .online, .visitors, .traces]
        }
    }

    private static func title(for subPage: UserSpaceSubPage, isSelf: Bool) -> String {
        switch subPage {
        case .profile:
            isSelf ? L10n.string("user_space.my_profile") : L10n.string("user_space.other_profile")
        case .threads:
            isSelf ? L10n.string("user_space.my_threads") : L10n.string("user_space.other_threads")
        case .replies:
            isSelf ? L10n.string("user_space.my_replies") : L10n.string("user_space.other_replies")
        case .myBlogs:
            isSelf ? L10n.string("user_space.my_blogs") : L10n.string("user_space.other_blogs")
        case .friendBlogs:
            L10n.string("user_space.friend_blogs")
        case .viewAllBlogs:
            L10n.string("user_space.view_all_blogs")
        case .friends:
            L10n.string("user_space.my_friends")
        case .online:
            L10n.string("user_space.online")
        case .visitors:
            L10n.string("user_space.visitors")
        case .traces:
            L10n.string("user_space.traces")
        }
    }

    private static func resolvedIsSelf(uid: String?, accountUID: String?) -> Bool {
        guard let uid else { return true }
        guard let accountUID else { return false }
        return uid == accountUID
    }

    private func resolveIsSelf() async {
        let accountUID = await accountUIDProvider()
        let resolved = Self.resolvedIsSelf(uid: uid, accountUID: accountUID)
        guard resolved != isSelf else { return }

        isSelf = resolved
        let supportedSubPages = Self.subPages(for: selectedSection, isSelf: resolved)
        if !supportedSubPages.contains(selectedSubPage) {
            selectedSubPage = supportedSubPages.first ?? .profile
            content = nil
            currentPage = 1
        }
    }
}

private extension UserSpaceSubPage {
    var section: UserSpaceSection {
        switch self {
        case .profile:
            .space
        case .threads, .replies:
            .threads
        case .myBlogs, .friendBlogs, .viewAllBlogs:
            .blogs
        case .friends, .online, .visitors, .traces:
            .friends
        }
    }
}
