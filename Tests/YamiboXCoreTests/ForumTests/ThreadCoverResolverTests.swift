import Foundation
import Testing
@testable import YamiboXCore

@Test func threadCoverResolverIncludesLaterOwnerFloorOnSamePage() throws {
    let owner = BlogReaderUser(uid: "7", name: "owner")
    let page = threadPage(posts: [
        post(floor: "1#", author: owner),
        post(floor: "2#", author: owner, image: "data/attachment/forum/second-floor.jpg")
    ])

    #expect(
        ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString ==
            "https://bbs.yamibo.com/data/attachment/forum/second-floor.jpg"
    )
}

@Test func threadCoverResolverIgnoresNonOwnerImages() throws {
    let owner = BlogReaderUser(uid: "7", name: "owner")
    let other = BlogReaderUser(uid: "8", name: "other")
    let page = threadPage(posts: [
        post(floor: "1#", author: owner),
        post(floor: "2#", author: other, image: "https://img.example.com/wrong.jpg"),
        post(floor: "3#", author: owner, image: "https://img.example.com/right.jpg")
    ])

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString == "https://img.example.com/right.jpg")
}

@Test func threadCoverResolverSortsCandidatePostsByFloor() throws {
    let owner = BlogReaderUser(uid: "7", name: "owner")
    let page = threadPage(posts: [
        post(floor: "5#", author: owner, image: "https://img.example.com/later.jpg"),
        post(floor: "1#", author: owner),
        post(floor: "2#", author: owner, image: "https://img.example.com/earlier.jpg")
    ])

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString == "https://img.example.com/earlier.jpg")
}

@Test func threadCoverResolverMatchesByPositiveUIDBeforeName() throws {
    let owner = BlogReaderUser(uid: "7", name: "same-name")
    let page = threadPage(posts: [
        post(floor: "1#", author: owner),
        post(floor: "2#", author: BlogReaderUser(uid: "8", name: "same-name"), image: "https://img.example.com/wrong.jpg"),
        post(floor: "3#", author: BlogReaderUser(uid: "7", name: "renamed"), image: "https://img.example.com/right.jpg")
    ])

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString == "https://img.example.com/right.jpg")
}

@Test func threadCoverResolverFallsBackToNameWhenOwnerUIDIsInvalid() throws {
    let owner = BlogReaderUser(uid: "0", name: "owner")
    let page = threadPage(posts: [
        post(floor: "1#", author: owner),
        post(floor: "2#", author: BlogReaderUser(uid: "9", name: "owner"), image: "https://img.example.com/name.jpg")
    ])

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString == "https://img.example.com/name.jpg")
}

@Test func threadCoverResolverConsumesFlatPostImages() throws {
    let owner = BlogReaderUser(uid: "7", name: "owner")
    let page = threadPage(posts: [
        post(floor: "1#", author: owner),
        post(
            floor: "2#",
            author: owner,
            images: ["https://img.example.com/flat.jpg"]
        )
    ])

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString == "https://img.example.com/flat.jpg")
}

@Test func threadCoverResolverNormalizesURLsAndFiltersStaticImages() throws {
    let owner = BlogReaderUser(uid: "7", name: "owner")
    let page = threadPage(posts: [
        post(floor: "1#", author: owner),
        post(
            floor: "2#",
            author: owner,
            images: [
                "static/image/common/none.gif",
                "static/image/smiley/default/smile.gif",
                "//img.example.com/cover.jpg"
            ]
        )
    ])

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page)?.absoluteString == "https://img.example.com/cover.jpg")
}

@Test func threadCoverResolverOnlyChecksFirstPage() async throws {
    let owner = BlogReaderUser(uid: "7", name: "owner")
    let firstPage = threadPage(
        posts: [post(floor: "1#", author: owner)],
        totalPages: 2
    )
    let repository = FakeThreadCoverPageRepository(fetchedPages: [
        ThreadCoverPageKey(authorID: nil, page: 1): firstPage,
        ThreadCoverPageKey(authorID: nil, page: 2): threadPage(
            posts: [post(floor: "3#", author: owner, image: "https://img.example.com/page2.jpg")],
            currentPage: 2,
            totalPages: 2
        )
    ])

    let resolved = await ThreadCoverResolver().resolve(
        thread: testThread,
        title: "title",
        repository: repository
    )

    #expect(resolved == nil)
    #expect(await repository.fetchCalls() == [
        ThreadCoverPageKey(authorID: nil, page: 1)
    ])
}

private let testThread = ThreadIdentity(
    tid: "900",
    fid: "49"
)

private func threadPage(
    posts: [ForumThreadPost],
    currentPage: Int = 1,
    totalPages: Int = 1
) -> ForumThreadPage {
    ForumThreadPage(
        thread: testThread,
        title: "title",
        posts: posts,
        pageNavigation: ForumPageNavigation(currentPage: currentPage, totalPages: totalPages)
    )
}

private func post(
    floor: String,
    author: BlogReaderUser,
    image: String? = nil,
    images: [String]? = nil
) -> ForumThreadPost {
    ForumThreadPost(
        postID: floor,
        floorText: floor,
        author: author,
        contentHTML: "",
        contentText: "",
        images: (images ?? image.map { [$0] } ?? []).map { ForumThreadPostImage(url: $0) }
    )
}

private struct ThreadCoverPageKey: Hashable, Sendable {
    var authorID: String?
    var page: Int
}

private actor FakeThreadCoverPageRepository: ThreadCoverPageResolving {
    private let cachedPages: [ThreadCoverPageKey: ForumThreadPage]
    private let fetchedPages: [ThreadCoverPageKey: ForumThreadPage]
    private var recordedFetchCalls: [ThreadCoverPageKey] = []

    init(
        cachedPages: [ThreadCoverPageKey: ForumThreadPage] = [:],
        fetchedPages: [ThreadCoverPageKey: ForumThreadPage] = [:]
    ) {
        self.cachedPages = cachedPages
        self.fetchedPages = fetchedPages
    }

    func cachedThreadPage(
        thread _: ThreadIdentity,
        title _: String,
        authorID: String?,
        page: Int
    ) async -> ForumThreadPage? {
        cachedPages[ThreadCoverPageKey(authorID: authorID, page: page)]
    }

    func fetchThreadPage(
        thread _: ThreadIdentity,
        title _: String,
        authorID: String?,
        page: Int
    ) async throws -> ForumThreadPage {
        let key = ThreadCoverPageKey(authorID: authorID, page: page)
        recordedFetchCalls.append(key)
        guard let page = fetchedPages[key] else {
            throw YamiboError.parsingFailed(context: "thread cover")
        }
        return page
    }

    func fetchCalls() -> [ThreadCoverPageKey] {
        recordedFetchCalls
    }
}
