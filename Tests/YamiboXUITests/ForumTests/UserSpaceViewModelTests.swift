import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class UserSpaceViewModelTests: XCTestCase {
    func testLoadFetchesProfileOnlyForProfileTab() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", repository: repository)

        await model.load()

        XCTAssertEqual(model.profile?.uid, "705216")
        XCTAssertEqual(model.selectedSection, .space)
        XCTAssertEqual(model.selectedSubPage, .profile)
        XCTAssertNil(model.content)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["profile:705216:张瑞泽"])
    }

    func testSelectingThreadsFetchesFirstPageAndPaginationFetchesNextPage() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", repository: repository)

        await model.selectTab(.threads)
        await model.goToPage(2)

        if case let .threads(page) = model.content {
            XCTAssertEqual(page.threads.map(\.tid), ["thread-2"])
        } else {
            XCTFail("Expected threads content")
        }
        XCTAssertEqual(model.currentPage, 2)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["threads:705216:1", "threads:705216:2"])
    }

    func testSelectingProfileLoadsProfileWhenMissing() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", repository: repository)

        await model.selectSubPage(.threads)
        model.profile = nil
        await model.selectSubPage(.profile)

        XCTAssertEqual(model.selectedSection, .space)
        XCTAssertEqual(model.selectedSubPage, .profile)
        XCTAssertEqual(model.profile?.uid, "705216")
        XCTAssertNil(model.content)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["threads:705216:1", "profile:705216:张瑞泽"])
    }

    func testInitialSectionAndSubPageLoadAndroidStyleUserSpaceGroup() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(
            uid: nil,
            titleHint: nil,
            initialSection: .blogs,
            initialSubPage: .friendBlogs,
            isSelf: true,
            repository: repository
        )

        await model.load()

        XCTAssertEqual(model.selectedSection, .blogs)
        XCTAssertEqual(model.selectedSubPage, .friendBlogs)
        XCTAssertEqual(model.navigationTitle, "我的日志")
        if case .blogs = model.content {
        } else {
            XCTFail("Expected blogs content")
        }
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["profile:self:", "friendBlogs:1"])
    }

    func testInitialTabFallsBackToFirstTabForRequestedSection() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(
            uid: "705216",
            titleHint: "张瑞泽",
            initialSection: .friends,
            initialSubPage: .myBlogs,
            isSelf: false,
            repository: repository
        )

        await model.load()

        XCTAssertEqual(model.selectedSection, .friends)
        XCTAssertEqual(model.selectedSubPage, .friends)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["profile:705216:张瑞泽", "friendPage:myFriend:1"])
    }

    func testSelectingBlogsStoresError() async throws {
        let repository = UserSpaceRepositoryStub(error: YamiboError.parsingFailed(context: "blogs"))
        let model = UserSpaceViewModel(uid: "705216", titleHint: nil, repository: repository)

        await model.selectTab(.myBlogs)

        XCTAssertNil(model.content)
        XCTAssertNotNil(model.errorMessage)
    }

    func testViewAllBlogsUsesSelectedFilter() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(uid: nil, titleHint: nil, isSelf: true, repository: repository)

        await model.selectSubPage(.viewAllBlogs)
        await model.selectViewAllBlogFilter(.hot)

        XCTAssertEqual(model.selectedSection, .blogs)
        XCTAssertEqual(model.viewAllBlogFilter, .hot)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["viewAllBlogs:latest:1", "viewAllBlogs:hot:1"])
    }

    func testBlogEditorIsAvailableOnlyForSelfBlogSection() async throws {
        let selfRepository = UserSpaceRepositoryStub()
        let selfModel = UserSpaceViewModel(uid: nil, titleHint: nil, isSelf: true, repository: selfRepository)
        let otherRepository = UserSpaceRepositoryStub()
        let otherModel = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", isSelf: false, repository: otherRepository)

        await selfModel.selectSection(.blogs)
        await otherModel.selectSection(.blogs)

        XCTAssertTrue(selfModel.canOpenBlogEditor)
        XCTAssertFalse(otherModel.canOpenBlogEditor)
    }

    func testNavigationTitleFollowsCurrentUserSpaceSection() async throws {
        let selfRepository = UserSpaceRepositoryStub()
        let selfModel = UserSpaceViewModel(uid: nil, titleHint: nil, isSelf: true, repository: selfRepository)
        let otherRepository = UserSpaceRepositoryStub()
        let otherModel = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", isSelf: false, repository: otherRepository)

        XCTAssertEqual(selfModel.navigationTitle, "我的资料")
        XCTAssertEqual(otherModel.navigationTitle, "张瑞泽的资料")

        await selfModel.selectSection(.blogs)
        await otherModel.selectSection(.threads)

        XCTAssertEqual(selfModel.navigationTitle, "我的日志")
        XCTAssertEqual(otherModel.navigationTitle, "张瑞泽 - Ta的主题")

        await selfModel.selectSubPage(.online)

        XCTAssertEqual(selfModel.navigationTitle, "在线成员")
    }

    func testLoadTreatsTargetUIDMatchingCurrentAccountAsSelf() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(
            uid: "705216",
            titleHint: "张瑞泽",
            currentAccountUID: "705216",
            repository: repository
        )

        await model.load()
        await model.beginAddFriend()

        XCTAssertTrue(model.isSelf)
        XCTAssertEqual(model.availableSubPages, [.profile])
        XCTAssertFalse(model.isAddFriendSheetPresented)
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["profile:705216:张瑞泽"])
    }

    func testAddFriendLoadsFormAndSubmitsRequest() async throws {
        let repository = UserSpaceRepositoryStub()
        let model = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", isSelf: false, repository: repository)
        model.profile = UserSpaceProfile(uid: "705216", username: "张瑞泽")

        await model.beginAddFriend()
        await model.submitAddFriend(note: "你好", groupID: 2)

        XCTAssertFalse(model.isAddFriendSheetPresented)
        XCTAssertEqual(model.addFriendResultMessage, "好友请求已送出")
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["addFriendForm:705216:张瑞泽", "addFriend:705216:form123:你好:2"])
    }

    /// generation-guard coverage: quickly switching sub-tabs must not let a
    /// slow response for the tab that's no longer selected land after the
    /// newly selected tab's faster response and overwrite its content.
    func testStaleSubTabResponseDoesNotOverwriteNewerSubTabContent() async throws {
        let repository = UserSpaceRepositoryStub()
        await repository.setGatedThreadsPages([1])
        let model = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", repository: repository)

        let staleTask = Task { await model.selectTab(.threads) }
        await repository.waitUntilThreadsBlocked()

        await model.selectTab(.replies)
        if case .replies = model.content {
        } else {
            XCTFail("Expected replies content")
        }
        XCTAssertEqual(model.selectedSubPage, .replies)

        await repository.releaseThreads()
        await staleTask.value

        if case .replies = model.content {
        } else {
            XCTFail("Expected replies content to remain after the stale threads response landed")
        }
        XCTAssertEqual(model.selectedSubPage, .replies)
    }

    /// Split-generation coverage: profile and content requests advance
    /// independent generations, so switching sub-tabs while the profile is
    /// still in flight must not get the still-relevant profile response
    /// discarded (which would leave the navigation title stuck on the
    /// unknown-user fallback with no way to recover on this screen).
    func testProfileResponseSurvivesSubTabSwitchWhileInFlight() async throws {
        let repository = UserSpaceRepositoryStub()
        await repository.setGatedProfile(true)
        let model = UserSpaceViewModel(uid: "705216", titleHint: nil, repository: repository)

        let profileTask = Task { await model.load() }
        await repository.waitUntilProfileBlocked()

        await model.selectTab(.threads)
        if case .threads = model.content {
        } else {
            XCTFail("Expected threads content")
        }

        await repository.releaseProfile()
        await profileTask.value

        XCTAssertEqual(model.profile?.uid, "705216")
        if case .threads = model.content {
        } else {
            XCTFail("Expected threads content to remain after the profile response landed")
        }
        XCTAssertFalse(model.isLoadingProfile)
        XCTAssertFalse(model.isLoadingContent)
    }

    /// Switching to the already-cached profile sub-page issues no request
    /// but must still invalidate any in-flight content request — its late
    /// response may not repopulate the content axis (or re-raise a spinner)
    /// behind the profile page.
    func testSwitchingToCachedProfileSubPageInvalidatesInFlightContentRequest() async throws {
        let repository = UserSpaceRepositoryStub()
        await repository.setGatedThreadsPages([1])
        let model = UserSpaceViewModel(uid: "705216", titleHint: "张瑞泽", repository: repository)
        model.profile = UserSpaceProfile(uid: "705216", username: "张瑞泽")

        let staleTask = Task { await model.selectTab(.threads) }
        await repository.waitUntilThreadsBlocked()

        await model.selectTab(.profile)
        XCTAssertEqual(model.selectedSubPage, .profile)
        XCTAssertFalse(model.isLoadingContent)

        await repository.releaseThreads()
        await staleTask.value

        XCTAssertNil(model.content)
        XCTAssertEqual(model.selectedSubPage, .profile)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingContent)
    }
}

private actor UserSpaceRepositoryStub: UserSpacePageLoading {
    let error: Error?
    var recordedCalls: [String] = []
    /// Gate used by the stale-response race test to hold a `fetchThreads`
    /// call in flight until the newer sub-tab's response has already landed.
    private var gatedThreadsPages: Set<Int> = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var isBlocking = false
    private var released = false
    /// Separate gate holding a `fetchProfile` call in flight while content
    /// requests come and go on their own generation axis.
    private var gatedProfile = false
    private var profileContinuation: CheckedContinuation<Void, Never>?
    private var isProfileBlocking = false
    private var profileReleased = false

    init(error: Error? = nil) {
        self.error = error
    }

    func fetchProfile(uid: String?, titleHint: String?) async throws -> UserSpaceProfile {
        recordedCalls.append("profile:\(uid ?? "self"):\(titleHint ?? "")")
        if gatedProfile {
            await waitForProfileIfNeeded()
        }
        if let error { throw error }
        return UserSpaceProfile(uid: uid ?? "self", username: titleHint ?? "User")
    }

    func fetchThreads(uid: String?, page: Int) async throws -> UserSpaceThreadPage {
        recordedCalls.append("threads:\(uid ?? "self"):\(page)")
        if gatedThreadsPages.contains(page) {
            await waitIfNeeded()
        }
        if let error { throw error }
        return UserSpaceThreadPage(
            threads: [ForumThreadSummary(tid: "thread-\(page)", title: "Thread", url: URL(string: "https://bbs.yamibo.com/thread-\(page)-1-1.html")!)],
            pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3)
        )
    }

    func fetchReplies(uid: String?, page: Int) async throws -> UserSpaceReplyPage {
        recordedCalls.append("replies:\(uid ?? "self"):\(page)")
        if let error { throw error }
        return UserSpaceReplyPage(replies: [])
    }

    func fetchBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage {
        recordedCalls.append("blogs:\(uid ?? "self"):\(page)")
        if let error { throw error }
        return UserSpaceBlogPage(blogs: [])
    }

    func fetchMyBlogs(uid: String?, page: Int) async throws -> UserSpaceBlogPage {
        recordedCalls.append("myBlogs:\(uid ?? "self"):\(page)")
        if let error { throw error }
        return UserSpaceBlogPage(blogs: [])
    }

    func fetchFriendBlogs(page: Int) async throws -> UserSpaceBlogPage {
        recordedCalls.append("friendBlogs:\(page)")
        if let error { throw error }
        return UserSpaceBlogPage(blogs: [])
    }

    func fetchViewAllBlogs(filter: UserSpaceViewAllBlogFilter, page: Int) async throws -> UserSpaceBlogPage {
        recordedCalls.append("viewAllBlogs:\(filter.rawValue):\(page)")
        if let error { throw error }
        return UserSpaceBlogPage(blogs: [])
    }

    func fetchFriendPage(type: UserSpaceFriendType, page: Int) async throws -> UserSpaceFriendPage {
        recordedCalls.append("friendPage:\(type.rawValue):\(page)")
        if let error { throw error }
        return UserSpaceFriendPage(friends: [])
    }

    func fetchAddFriendForm(uid: String, nameHint: String?) async throws -> UserSpaceAddFriendForm {
        recordedCalls.append("addFriendForm:\(uid):\(nameHint ?? "")")
        if let error { throw error }
        return UserSpaceAddFriendForm(
            uid: uid,
            name: nameHint,
            formHash: "form123",
            options: [
                UserSpaceAddFriendOption(id: 1, name: "好友"),
                UserSpaceAddFriendOption(id: 2, name: "同好")
            ]
        )
    }

    func addFriend(uid: String, formHash: String, note: String, groupID: Int) async throws -> String {
        recordedCalls.append("addFriend:\(uid):\(formHash):\(note):\(groupID)")
        if let error { throw error }
        return "好友请求已送出"
    }

    func calls() -> [String] {
        recordedCalls
    }

    func setGatedThreadsPages(_ pages: Set<Int>) {
        gatedThreadsPages = pages
    }

    private func waitIfNeeded() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isBlocking = true
        }
    }

    func waitUntilThreadsBlocked() async {
        while !isBlocking {
            await Task.yield()
        }
    }

    func releaseThreads() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func setGatedProfile(_ gated: Bool) {
        gatedProfile = gated
    }

    private func waitForProfileIfNeeded() async {
        guard !profileReleased else { return }
        await withCheckedContinuation { continuation in
            profileContinuation = continuation
            isProfileBlocking = true
        }
    }

    func waitUntilProfileBlocked() async {
        while !isProfileBlocking {
            await Task.yield()
        }
    }

    func releaseProfile() {
        profileReleased = true
        profileContinuation?.resume()
        profileContinuation = nil
    }
}
