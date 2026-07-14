import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Test func forumNovelDetailContinueStartsAtFirstViewWithoutHistory() throws {
    let model = try makeForumNovelDetailViewModel()

    let context = model.continueLaunchContext()

    #expect(context.source == .forum)
    #expect(context.initialView == 1)
    #expect(context.initialResumePoint == nil)
    #expect(context.authorID == "42")
}

@MainActor
@Test func forumNovelDetailContinueUsesReadingProgressResumePointWhenAvailable() throws {
    let model = try makeForumNovelDetailViewModel()
    let resumePoint = NovelResumePoint(
        view: 5,
        displayedTextOffset: 128,
        chapterOrdinal: 4,
        chapterTitle: "第五章",
        segmentProgress: 0.4,
        authorID: "99",
        readingModeHint: .vertical
    )
    model.favoriteActions.favorite = Favorite(
        title: "收藏标题",
        threadID: model.context.thread.tid,
        type: .novel
    )
    model.readingProgress = ReadingProgressRecord(
        threadID: model.context.thread.tid,
        kind: .novel,
        novel: NovelReadingProgressRecord(
            lastView: 5,
            lastChapter: "第五章",
            authorID: "99",
            novelResumePoint: resumePoint
        )
    )

    let context = model.continueLaunchContext()

    #expect(context.source == .resume)
    #expect(context.threadTitle == "收藏标题")
    #expect(context.initialView == 5)
    #expect(context.authorID == "99")
    #expect(context.initialResumePoint == resumePoint)
}

@MainActor
@Test func forumNovelDetailContinueUsesIndependentReadingProgressWithoutFavorite() throws {
    let model = try makeForumNovelDetailViewModel()
    let resumePoint = NovelResumePoint(
        view: 4,
        displayedTextOffset: 96,
        chapterOrdinal: 3,
        chapterTitle: "第四章",
        segmentProgress: 0.3,
        authorID: "77",
        readingModeHint: .vertical
    )
    model.favoriteActions.favorite = nil
    model.readingProgress = ReadingProgressRecord(
        threadID: model.context.thread.tid,
        kind: .novel,
        novel: NovelReadingProgressRecord(
            lastView: 4,
            lastChapter: "第四章",
            authorID: "77",
            novelResumePoint: resumePoint,
            novelMaxView: 6,
            novelDocumentSurfaceProgressPercent: 33
        )
    )

    let context = model.continueLaunchContext()

    #expect(model.hasReadingProgress)
    #expect(model.headerSummary.isFavorited == false)
    #expect(model.headerSummary.readingProgressText == "第四章")
    #expect(context.source == .resume)
    #expect(context.initialView == 4)
    #expect(context.authorID == "77")
    #expect(context.initialResumePoint == resumePoint)
}

@MainActor
@Test func forumNovelDetailContinueUsesStoredChapterReadingProgress() throws {
    let model = try makeForumNovelDetailViewModel()
    model.readingProgress = ReadingProgressRecord(
        threadID: model.context.thread.tid,
        kind: .novel,
        novel: NovelReadingProgressRecord(
            lastView: 1,
            lastChapter: "第一章"
        )
    )

    let context = model.continueLaunchContext()

    #expect(model.hasReadingProgress)
    #expect(context.source == .resume)
    #expect(context.initialView == 1)
    #expect(model.headerSummary.readingProgressText == "第一章")
}

@MainActor
@Test func forumNovelDetailHeaderSummaryUsesThreadPageCoverCandidateWhenPersistedCoverMissing() throws {
    let model = try makeForumNovelDetailViewModel()
    let ignoredURL = try #require(URL(string: "https://bbs.yamibo.com/static/image/smiley/default/none.gif"))
    let coverURL = try #require(URL(string: "https://bbs.yamibo.com/data/attachment/forum/cover.jpg"))
    model.chapters = [
        ForumNovelChapterSummary(id: "1|序章", title: "序章", view: 1),
        ForumNovelChapterSummary(id: "1|第一章", title: "第一章", view: 1)
    ]
    model.threadPage = ForumThreadPage(
        thread: ThreadIdentity(
            tid: "900",
            fid: "123"
        ),
        title: "解析标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "楼主",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                postedAtText: "2026-6-1 10:00",
                lastEditedText: "本帖最后由 楼主名 于 2026-6-2 12:00 编辑",
                contentHTML: "",
                contentText: "首楼简介\n正文",
                contentBlocks: [
                    ForumThreadContentBlock(
                        id: "ignored",
                        kind: .image(ForumThreadImageBlock(url: ignoredURL, isEmoticon: true))
                    ),
                    ForumThreadContentBlock(
                        id: "cover",
                        kind: .image(ForumThreadImageBlock(
                            url: coverURL
                        ))
                    )
                ],
                images: [
                    ForumThreadPostImage(url: ignoredURL.absoluteString),
                    ForumThreadPostImage(url: coverURL.absoluteString)
                ]
            )
        ],
        totalViews: 321,
        totalReplies: 45,
        forumName: "原创小说"
    )

    let summary = model.headerSummary

    #expect(summary.title == "解析标题")
    #expect(summary.threadID == model.context.thread.tid)
    #expect(summary.authorID == "42")
    #expect(summary.authorName == "楼主名")
    #expect(summary.postedAtText == "2026-6-1 10:00")
    #expect(summary.lastUpdatedText == "2026-6-2 12:00")
    #expect(summary.totalViews == 321)
    #expect(summary.totalReplies == 45)
    #expect(summary.forumName == "原创小说")
    #expect(summary.chapterCount == 2)
    #expect(summary.coverURL == coverURL)
    #expect(summary.firstFloorPreviewText == nil)
}

@MainActor
@Test func forumNovelDetailUsesSanitizedDiscuzTitle() throws {
    let model = try makeForumNovelDetailViewModel()
    model.threadPage = ForumThreadPage(
        thread: model.context.thread,
        title: "文学区版规已更新 请各位会员阅读知悉 - 文學區 - 百合会 - 手机版 - Powered by Discuz!",
        posts: [
            ForumThreadPost(
                postID: "1001",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "正文",
                contentBlocks: []
            )
        ]
    )

    #expect(model.navigationTitle == "文学区版规已更新 请各位会员阅读知悉")
    #expect(model.headerSummary.title == "文学区版规已更新 请各位会员阅读知悉")
}

@MainActor
@Test func forumNovelDetailHeaderFallsBackToPostedAtForLastUpdatedText() throws {
    let model = try makeForumNovelDetailViewModel()
    model.threadPage = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                postedAtText: "2026-6-1 10:00",
                lastEditedText: nil,
                contentHTML: "",
                contentText: "正文",
                contentBlocks: []
            )
        ]
    )

    #expect(model.headerSummary.lastUpdatedText == "2026-6-1 10:00")
}

@MainActor
@Test func forumNovelDetailHeaderPrefersPersistedContentCover() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let key = ContentCoverKey(targetType: .thread, targetID: "900")
    let persisted = try #require(URL(string: "https://img.example.com/persisted.jpg"))
    let pageCandidate = try #require(URL(string: "https://img.example.com/page.jpg"))
    try await coverStore.setAutomaticCover(persisted, for: key)
    let dependencies = try makeForumDetailDependencies(contentCoverStore: coverStore)
    let model = try makeForumNovelDetailViewModel(dependencies: dependencies)
    model.contentCover = await coverStore.cover(for: key)
    model.threadPage = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "1#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "首楼",
                contentBlocks: [
                    ForumThreadContentBlock(
                        id: "page",
                        kind: .image(ForumThreadImageBlock(url: pageCandidate))
                    )
                ]
            )
        ]
    )

    #expect(model.headerSummary.coverURL == persisted)
}

@MainActor
@Test func forumNovelDetailReloadStoresInitialPageCoverWithoutRefetchingThreadPage() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-initial-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeForumDetailDependencies(contentCoverStore: coverStore)
    let initialImage = try #require(URL(string: "https://img.example.com/initial-owner.jpg"))
    let threadPageLoader = FakeForumNovelThreadPageLoader(pages: [
        1: ForumThreadPage(
            thread: ThreadIdentity(tid: "900", fid: "49"),
            title: "小说标题",
            posts: [
                ForumThreadPost(
                    postID: "1001",
                    floorText: "楼主",
                    author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                    contentHTML: "",
                    contentText: "首楼封面",
                    contentBlocks: [
                        ForumThreadContentBlock(
                            id: "initial-image",
                            kind: .image(ForumThreadImageBlock(url: initialImage))
                        )
                    ],
                    images: [
                        ForumThreadPostImage(url: initialImage.absoluteString)
                    ]
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
        )
    ])
    let model = try makeForumNovelDetailViewModel(
        dependencies: dependencies,
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: threadPageLoader
    )

    await model.reload()

    let key = ContentCoverKey(targetType: .thread, targetID: "900")
    let cover = await coverStore.cover(for: key)
    #expect(cover?.resolvedURL == initialImage)
    #expect(model.headerSummary.coverURL == initialImage)
    #expect(threadPageLoader.threadFetchCalls().isEmpty)
    #expect(threadPageLoader.novelFetchCalls() == [1])
}

@MainActor
@Test func forumNovelDetailReloadUsesCachedInitialThreadPageWithoutFetching() async throws {
    let cachedPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "900", fid: "49"),
        title: "缓存小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "楼主",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "缓存首楼"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )
    let threadPageLoader = FakeForumNovelThreadPageLoader(pages: [:], cachedPages: [1: cachedPage])
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: threadPageLoader
    )

    await model.reload()

    #expect(model.headerSummary.title == "缓存小说标题")
    #expect(model.chapters.map(\.title) == ["缓存首楼"])
    #expect(threadPageLoader.cachedNovelCalls() == [1])
    #expect(threadPageLoader.novelFetchCalls().isEmpty)
}

@MainActor
@Test func forumNovelDetailReloadKeepsCachedInitialThreadPageWhenReaderDocumentTimesOut() async throws {
    let cachedPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "900", fid: "49"),
        title: "缓存小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "楼主",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "缓存首楼\n正文"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )
    let threadPageLoader = FakeForumNovelThreadPageLoader(pages: [:], cachedPages: [1: cachedPage])
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FailingForumNovelDocumentLoader(error: URLError(.timedOut)),
        threadPageLoader: threadPageLoader
    )

    await model.reload()

    #expect(model.errorMessage == nil)
    #expect(model.headerSummary.title == "缓存小说标题")
    #expect(model.headerSummary.firstFloorPreviewText == "缓存首楼\n正文")
    #expect(model.chapters.map(\.title) == ["缓存首楼"])
    #expect(threadPageLoader.cachedNovelCalls() == [1])
    #expect(threadPageLoader.novelFetchCalls().isEmpty)
}

@MainActor
@Test func forumNovelDetailLoadChapterSectionUsesCachedThreadPageWithoutFetching() async throws {
    let firstPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "900", fid: "49"),
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "楼主",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "第一章"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 2)
    )
    let secondPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "900", fid: "49"),
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "2001",
                floorText: "2#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "第二章"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 2, totalPages: 2)
    )
    let threadPageLoader = FakeForumNovelThreadPageLoader(
        pages: [:],
        cachedPages: [
            1: firstPage,
            2: secondPage
        ]
    )
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: threadPageLoader
    )

    await model.reload()
    await model.loadChapterSection(page: 2)

    #expect(model.chapterSections.flatMap(\.chapters).map(\.title).contains("第二章"))
    #expect(threadPageLoader.cachedNovelCalls() == [1, 2])
    #expect(threadPageLoader.novelFetchCalls().isEmpty)
}

@MainActor
@Test func forumNovelDetailRefreshContentCoverStoresOwnerPostCandidateOnly() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-auto-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeForumDetailDependencies(contentCoverStore: coverStore)
    let model = try makeForumNovelDetailViewModel(dependencies: dependencies)
    let key = ContentCoverKey(targetType: .thread, targetID: "900")
    let replyImage = try #require(URL(string: "https://img.example.com/reply.jpg"))
    let ownerImage = try #require(URL(string: "https://img.example.com/owner.jpg"))
    let page = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "1#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "首楼无图",
                contentBlocks: []
            ),
            ForumThreadPost(
                postID: "1002",
                floorText: "2#",
                author: BlogReaderUser(uid: "99", name: "读者", avatarURL: nil),
                contentHTML: "",
                contentText: "回复图",
                contentBlocks: [
                    ForumThreadContentBlock(
                        id: "reply",
                        kind: .image(ForumThreadImageBlock(url: replyImage))
                    )
                ],
                images: [
                    ForumThreadPostImage(url: replyImage.absoluteString)
                ]
            ),
            ForumThreadPost(
                postID: "1003",
                floorText: "3#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "楼主补图",
                contentBlocks: [
                    ForumThreadContentBlock(
                        id: "owner",
                        kind: .image(ForumThreadImageBlock(url: ownerImage))
                    )
                ],
                images: [
                    ForumThreadPostImage(url: ownerImage.absoluteString)
                ]
            )
        ]
    )

    #expect(ThreadCoverResolver.findThreadCoverCandidate(in: page) == ownerImage)

    await model.refreshContentCover(from: page)

    let cover = try #require(await coverStore.cover(for: key))
    #expect(cover.automaticCoverURL == ownerImage)
    #expect(model.contentCover?.resolvedURL == ownerImage)
}

@MainActor
@Test func forumNovelDetailRefreshContentCoverDoesNotStoreWithoutFirstFloorOwner() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-cover-no-owner")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeForumDetailDependencies(contentCoverStore: coverStore)
    let model = try makeForumNovelDetailViewModel(dependencies: dependencies)
    let key = ContentCoverKey(targetType: .thread, targetID: "900")
    let page = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1002",
                floorText: "2#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "非首楼图片",
                contentBlocks: [
                    ForumThreadContentBlock(
                        id: "image",
                        kind: .image(ForumThreadImageBlock(
                            url: try #require(URL(string: "https://img.example.com/not-owner-seed.jpg"))
                        ))
                    )
                ],
                images: [
                    ForumThreadPostImage(url: "https://img.example.com/not-owner-seed.jpg")
                ]
            )
        ]
    )

    await model.refreshContentCover(from: page)

    #expect(await coverStore.cover(for: key) == nil)
    #expect(model.contentCover == nil)
}

@MainActor
@Test func forumNovelDetailReloadDoesNotScanLaterThreadPagesForCover() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-later-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeForumDetailDependencies(contentCoverStore: coverStore)
    let threadPageLoader = FakeForumNovelThreadPageLoader(pages: [
        1: ForumThreadPage(
            thread: ThreadIdentity(tid: "900", fid: "49"),
            title: "小说标题",
            posts: [
                ForumThreadPost(
                    postID: "1001",
                    floorText: "楼主",
                    author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                    contentHTML: "",
                    contentText: "首楼无图",
                    contentBlocks: []
                ),
                ForumThreadPost(
                    postID: "1002",
                    floorText: "2#",
                    author: BlogReaderUser(uid: "99", name: "读者", avatarURL: nil),
                    contentHTML: "",
                    contentText: "读者图",
                    contentBlocks: [
                        ForumThreadContentBlock(
                            id: "reader-image",
                            kind: .image(ForumThreadImageBlock(
                                url: try #require(URL(string: "https://img.example.com/reader.jpg"))
                            ))
                        )
                    ],
                    images: [
                        ForumThreadPostImage(url: "https://img.example.com/reader.jpg")
                    ]
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 2)
        ),
        2: ForumThreadPage(
            thread: ThreadIdentity(tid: "900", fid: "49"),
            title: "小说标题",
            posts: [
                ForumThreadPost(
                    postID: "2001",
                    floorText: "3#",
                    author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                    contentHTML: "",
                    contentText: "楼主补图",
                    contentBlocks: [
                        ForumThreadContentBlock(
                            id: "owner-image",
                            kind: .image(ForumThreadImageBlock(
                                url: try #require(URL(string: "https://img.example.com/owner-later.jpg"))
                            ))
                        )
                    ],
                    images: [
                        ForumThreadPostImage(url: "https://img.example.com/owner-later.jpg")
                    ]
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: 2, totalPages: 2)
        )
    ])
    let model = try makeForumNovelDetailViewModel(
        dependencies: dependencies,
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: threadPageLoader
    )

    await model.reload()

    let key = ContentCoverKey(targetType: .thread, targetID: "900")
    let cover = await coverStore.cover(for: key)
    #expect(cover == nil)
    #expect(model.headerSummary.coverURL == nil)
    #expect(threadPageLoader.threadFetchCalls().isEmpty)
    #expect(threadPageLoader.novelFetchCalls() == [1])
}

@MainActor
@Test func forumNovelDetailReusesLoadedChapterPagesUntilReload() async throws {
    let firstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "第一章")
    let secondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "第二章")
    let loader = FakeForumNovelThreadPageLoader(pages: [
        1: firstPage,
        2: secondPage
    ])
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.reload()

    #expect(loader.novelFetchCalls() == [1])
    #expect(model.expandedChapterPages == [1])
    #expect(model.chapterSections.map(\.page) == [1, 2])
    #expect(model.chapterSections[0].chapters.map(\.title) == ["第一章"])
    #expect(model.chapterSections[1].isLoaded == false)

    await model.toggleChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2])
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[1].isLoaded)
    #expect(model.chapterSections[1].chapters.map(\.title) == ["第二章"])

    await model.toggleChapterSection(page: 2)
    await model.toggleChapterSection(page: 2)
    await model.loadChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2])
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[1].chapters.map(\.title) == ["第二章"])

    await model.reload()

    #expect(loader.novelFetchCalls() == [1, 2, 1])
    #expect(model.expandedChapterPages == [1])
    #expect(model.chapterSections[1].isLoaded == false)

    await model.toggleChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2, 1, 2])
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[1].chapters.map(\.title) == ["第二章"])
}

@MainActor
@Test func forumNovelDetailRefreshBypassesCacheClearsPersistentPagesAndReloadsFirstPage() async throws {
    let cachedFirstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "缓存第一章")
    let cachedSecondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "缓存第二章")
    let freshFirstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "刷新第一章")
    let freshSecondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "刷新第二章")
    let loader = FakeForumNovelThreadPageLoader(
        pages: [
            1: freshFirstPage,
            2: freshSecondPage
        ],
        cachedPages: [
            1: cachedFirstPage,
            2: cachedSecondPage
        ]
    )
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.reload()
    await model.toggleChapterSection(page: 2)

    #expect(model.chapterSections[0].chapters.map(\.title) == ["缓存第一章"])
    #expect(model.chapterSections[1].chapters.map(\.title) == ["缓存第二章"])
    #expect(loader.novelFetchCalls().isEmpty)

    await model.refresh()

    #expect(loader.cachedNovelCalls() == [1, 2])
    #expect(loader.novelFetchCalls() == [1])
    #expect(loader.clearedThreadIDs() == ["900"])
    #expect(loader.storedPages() == [
        ForumNovelThreadPageStore(authorID: "42", page: 1, title: "小说标题")
    ])
    #expect(model.favoriteActions.transientMessage == nil)
    #expect(model.expandedChapterPages == [1])
    #expect(model.chapterSections[0].chapters.map(\.title) == ["刷新第一章"])
    #expect(model.chapterSections[1].isLoaded == false)

    await model.toggleChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2])
    #expect(model.chapterSections[1].chapters.map(\.title) == ["刷新第二章"])
}

@MainActor
@Test func forumNovelDetailRefreshFailurePreservesExistingContentAndShowsTransientMessage() async throws {
    let cachedFirstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "缓存第一章")
    let cachedSecondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "缓存第二章")
    let loader = FakeForumNovelThreadPageLoader(
        pages: [
            1: cachedFirstPage,
            2: cachedSecondPage
        ],
        cachedPages: [
            1: cachedFirstPage,
            2: cachedSecondPage
        ],
        failuresByPage: [
            1: [FakeForumNovelThreadPageLoaderError.plannedFailure(page: 1)]
        ]
    )
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.reload()
    await model.toggleChapterSection(page: 2)
    await model.refresh()

    #expect(model.errorMessage == nil)
    #expect(model.favoriteActions.transientMessage == L10n.string("forum.novel_detail.refresh_failed", FakeForumNovelThreadPageLoaderError.plannedFailure(page: 1).localizedDescription))
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[0].chapters.map(\.title) == ["缓存第一章"])
    #expect(model.chapterSections[1].chapters.map(\.title) == ["缓存第二章"])
    #expect(loader.clearedThreadIDs().isEmpty)
    #expect(loader.storedPages().isEmpty)
}

@MainActor
@Test func forumNovelDetailRefreshFailureWithoutExistingContentUsesPageError() async throws {
    let loader = FakeForumNovelThreadPageLoader(
        pages: [:],
        failuresByPage: [
            1: [FakeForumNovelThreadPageLoaderError.plannedFailure(page: 1)]
        ]
    )
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.refresh()

    #expect(model.threadPage == nil)
    #expect(model.chapters.isEmpty)
    #expect(model.favoriteActions.transientMessage == nil)
    #expect(model.errorMessage == FakeForumNovelThreadPageLoaderError.plannedFailure(page: 1).localizedDescription)
}

@MainActor
@Test func forumNovelDetailKnownAuthorLoadsInitialPageOnce() async throws {
    let loader = FakeForumNovelThreadPageLoader(pages: [
        1: try makeNovelDetailThreadPage(page: 1, totalPages: 1, postID: "1001", chapterTitle: "第一章")
    ])
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader,
        authorID: "42"
    )

    await model.reload()
    await model.refresh()

    #expect(loader.cachedNovelCalls() == [1])
    #expect(loader.novelFetchCalls() == [1, 1])
    #expect(model.headerSummary.authorID == "42")
}

@MainActor
@Test func forumNovelDetailMissingAuthorDiscoversAuthorBeforeLoadingContent() async throws {
    let loader = FakeForumNovelThreadPageLoader(pages: [
        1: try makeNovelDetailThreadPage(page: 1, totalPages: 1, postID: "1001", chapterTitle: "第一章")
    ])
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader,
        authorID: nil
    )

    await model.reload()

    #expect(loader.cachedNovelCalls() == [1, 1])
    #expect(loader.novelFetchCalls() == [1, 1])
    #expect(model.headerSummary.authorID == "42")
    #expect(model.chapters.map(\.title) == ["第一章"])
}

@MainActor
@Test func forumNovelDetailDoesNotCacheFailedChapterPageLoads() async throws {
    let loader = FakeForumNovelThreadPageLoader(
        pages: [
            1: try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "第一章"),
            2: try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "第二章")
        ],
        failuresByPage: [
            2: [FakeForumNovelThreadPageLoaderError.plannedFailure(page: 2)]
        ]
    )
    let model = try makeForumNovelDetailViewModel(
        documentLoader: FakeForumNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.reload()
    await model.toggleChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2])
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[1].isLoaded == false)
    #expect(model.chapterSections[1].errorMessage != nil)
    #expect(model.chapterSections[1].chapters.isEmpty)

    await model.loadChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2, 2])
    #expect(model.chapterSections[1].isLoaded)
    #expect(model.chapterSections[1].errorMessage == nil)
    #expect(model.chapterSections[1].chapters.map(\.title) == ["第二章"])
}

@MainActor
@Test func forumNovelDetailGroupsChapterDirectoryByThreadPage() throws {
    let model = try makeForumNovelDetailViewModel()
    let firstPage = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                    floorText: "楼主",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "序章\n正文",
                contentBlocks: []
            ),
            ForumThreadPost(
                postID: "1002",
                floorText: "2#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "第一章\n正文",
                contentBlocks: []
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 2)
    )
    let secondPage = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "2001",
                floorText: "11#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "第二章\n正文",
                contentBlocks: []
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 2, totalPages: 2)
    )

    let sections = ForumNovelDetailViewModel.chapterSections(
        from: [
            1: firstPage,
            2: secondPage
        ],
        totalPages: 2
    )

    #expect(sections.map(\.page) == [1, 2])
    #expect(sections[0].chapters.map(\.title) == ["序章", "第一章"])
    #expect(sections[0].chapters.map(\.view) == [1, 1])
    #expect(sections[0].chapters.map(\.postID) == ["1001", "1002"])
    #expect(sections[0].chapters[0].resumePoint?.view == 1)
    #expect(sections[0].chapters[0].resumePoint?.chapterIdentity?.rawValue == "post:1001#chapter:0")
    #expect(sections[0].chapters[0].resumePoint?.textSegmentIdentity?.rawValue == "post:1001#chapter:0#text:0")
    #expect(sections[1].chapters.map(\.title) == ["第二章"])
    #expect(sections[1].chapters.map(\.view) == [2])
    #expect(sections[1].chapters.map(\.floorText) == ["11#"])
}

@MainActor
@Test func forumNovelDetailChapterTapUsesPostResumePoint() throws {
    let model = try makeForumNovelDetailViewModel()
    let section = ForumNovelDetailViewModel.chapterSections(
        from: [
            1: ForumThreadPage(
                thread: model.context.thread,
                title: "小说标题",
                posts: [
                    ForumThreadPost(
                        postID: "1001",
                        floorText: "1#",
                        author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                        contentHTML: "",
                        contentText: "序章\n正文",
                        contentBlocks: []
                    )
                ]
            )
        ],
        totalPages: 1
    )[0]

    let launchContext = model.launchContext(for: section.chapters[0])

    #expect(launchContext.initialView == 1)
    #expect(launchContext.authorID == "42")
    #expect(launchContext.initialResumePoint?.chapterIdentity?.rawValue == "post:1001#chapter:0")
    #expect(launchContext.initialResumePoint?.chapterTitle == "序章")
}

@MainActor
@Test func forumNovelDetailChapterDirectoryUsesReaderAuthorReplyVisibilitySetting() throws {
    let model = try makeForumNovelDetailViewModel()
    let page = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "1#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "第一章<br>正文",
                contentText: "第一章\n正文"
            ),
            ForumThreadPost(
                postID: "1002",
                floorText: "2#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: #"<div class="quote">发表于 1 小时前</div>作者回复<br>正文"#,
                contentText: "发表于 1 小时前\n作者回复\n正文"
            ),
            ForumThreadPost(
                postID: "1003",
                floorText: "3#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "第二章<br>正文",
                contentText: "第二章\n正文"
            )
        ]
    )

    let sections = ForumNovelDetailViewModel.chapterSections(
        from: [1: page],
        totalPages: 1,
        novelReaderSettings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false)
    )

    #expect(sections[0].chapters.map(\.title) == ["第一章", "第二章"])
    #expect(sections[0].chapters.map(\.postID) == ["1001", "1003"])
}

@MainActor
@Test func forumNovelDetailChapterTitleUsesReaderParserTitle() throws {
    let model = try makeForumNovelDetailViewModel()
    let page = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "1#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "引用里的旧标题\n真正章节\n正文",
                contentBlocks: [
                    ForumThreadContentBlock(
                        id: "quote",
                        kind: .quote([
                            ForumThreadContentBlock(
                                id: "quote-text",
                                kind: .text(ForumThreadTextBlock(text: "引用里的旧标题"))
                            )
                        ])
                    ),
                    ForumThreadContentBlock(
                        id: "body",
                        kind: .text(ForumThreadTextBlock(text: "真正章节\n正文"))
                    )
                ]
            )
        ]
    )

    let sections = ForumNovelDetailViewModel.chapterSections(from: [1: page], totalPages: 1)

    #expect(sections[0].chapters.map(\.title) == ["引用里的旧标题"])
}

@MainActor
@Test func forumNovelDetailMarksCurrentReadChapterFromReadingProgressResumePoint() throws {
    let model = try makeForumNovelDetailViewModel()
    model.readingProgress = ReadingProgressRecord(
        threadID: model.context.thread.tid,
        kind: .novel,
        novel: NovelReadingProgressRecord(
            lastView: 1,
            lastChapter: "第一章",
            novelResumePoint: NovelResumePoint(
                view: 1,
                chapterIdentity: NovelChapterIdentity(rawValue: "post:1002#chapter:0"),
                displayedTextOffset: 20,
                chapterOrdinal: 1,
                chapterTitle: "第一章",
                segmentProgress: 0.2,
                readingModeHint: .vertical
            ),
            novelDocumentSurfaceProgressPercent: 20
        )
    )
    let firstPage = ForumThreadPage(
        thread: model.context.thread,
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: "1001",
                floorText: "1#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "序章\n正文",
                contentBlocks: []
            ),
            ForumThreadPost(
                postID: "1002",
                floorText: "2#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "第一章\n正文",
                contentBlocks: []
            )
        ]
    )

    let sections = ForumNovelDetailViewModel.chapterSections(
        from: [1: firstPage],
        totalPages: 1,
        readingProgress: model.readingProgress,
        favorite: model.favoriteActions.favorite
    )

    #expect(sections[0].chapters.map(\.isCurrentRead) == [false, true])
    #expect(sections[0].chapters[1].progressText == nil)
    #expect(model.headerSummary.readingProgressText == "第一章")
}

@MainActor
@Test func forumNovelDetailMarksOnlyIdentityMatchedFloorWhenChapterTitlesDuplicate() throws {
    let model = try makeForumNovelDetailViewModel()
    model.readingProgress = ReadingProgressRecord(
        threadID: model.context.thread.tid,
        kind: .novel,
        novel: NovelReadingProgressRecord(
            lastView: 1,
            lastChapter: "喜歡的人和義妹",
            novelResumePoint: NovelResumePoint(
                view: 1,
                chapterIdentity: NovelChapterIdentity(rawValue: "post:1002#chapter:0"),
                displayedTextOffset: 20,
                chapterOrdinal: 1,
                chapterTitle: "喜歡的人和義妹",
                segmentProgress: 0.2,
                readingModeHint: .vertical
            ),
            novelDocumentSurfaceProgressPercent: 20
        )
    )
    let posts = ["1001", "1002", "1003"].map { postID in
        ForumThreadPost(
            postID: postID,
            floorText: "\(postID)#",
            author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
            contentHTML: "",
            contentText: "喜歡的人和義妹\n正文",
            contentBlocks: []
        )
    }
    let firstPage = ForumThreadPage(thread: model.context.thread, title: "小说标题", posts: posts)

    let sections = ForumNovelDetailViewModel.chapterSections(
        from: [1: firstPage],
        totalPages: 1,
        readingProgress: model.readingProgress,
        favorite: model.favoriteActions.favorite
    )

    #expect(sections[0].chapters.map(\.title) == ["喜歡的人和義妹", "喜歡的人和義妹", "喜歡的人和義妹"])
    #expect(sections[0].chapters.map(\.isCurrentRead) == [false, true, false])
}

@MainActor
@Test func forumNovelDetailTitleFallbackMarksOnlyFirstDuplicateWhenNoResumePointIdentityExists() throws {
    let model = try makeForumNovelDetailViewModel()
    model.readingProgress = ReadingProgressRecord(
        threadID: model.context.thread.tid,
        kind: .novel,
        novel: NovelReadingProgressRecord(
            lastView: 1,
            lastChapter: "喜歡的人和義妹"
        )
    )
    let posts = ["1001", "1002", "1003"].map { postID in
        ForumThreadPost(
            postID: postID,
            floorText: "\(postID)#",
            author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
            contentHTML: "",
            contentText: "喜歡的人和義妹\n正文",
            contentBlocks: []
        )
    }
    let firstPage = ForumThreadPage(thread: model.context.thread, title: "小说标题", posts: posts)

    let sections = ForumNovelDetailViewModel.chapterSections(
        from: [1: firstPage],
        totalPages: 1,
        readingProgress: model.readingProgress,
        favorite: model.favoriteActions.favorite
    )

    #expect(sections[0].chapters.map(\.isCurrentRead) == [true, false, false])
}

@MainActor
@Test func forumNovelDetailRefreshesReadingProgressWhenReadingProgressStoreChanges() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-progress-refresh")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )
    let dependencies = try makeForumDetailDependencies(
        contentCoverStore: ContentCoverStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "content-covers"
        ),
        readingProgressStore: readingProgressStore
    )
    let model = try makeForumNovelDetailViewModel(dependencies: dependencies)
    let threadID = model.context.thread.tid

    try await readingProgressStore.saveNovel(
        NovelReadingPosition(
            threadID: threadID,
            view: 1,
            chapterTitle: "第一章",
            documentSurfaceProgressPercent: 10
        )
    )
    model.readingProgress = await readingProgressStore.load(threadID: threadID)
    #expect(model.headerSummary.readingProgressText == "第一章")
    await Task.yield()

    try await readingProgressStore.saveNovel(
        NovelReadingPosition(
            threadID: threadID,
            view: 2,
            maxView: 3,
            chapterTitle: "第二章",
            authorID: "42",
            resumePoint: NovelResumePoint(
                view: 2,
                chapterIdentity: NovelChapterIdentity(rawValue: "post:2001#chapter:0"),
                displayedTextOffset: 80,
                chapterOrdinal: 1,
                chapterTitle: "第二章",
                segmentProgress: 0.8,
                authorID: "42",
                readingModeHint: .vertical
            )
        )
    )

    for _ in 0..<20 where model.readingProgress?.novel?.lastView != 2 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(model.readingProgress?.novel?.lastView == 2)
    #expect(model.readingProgress?.novel?.novelResumePoint?.chapterTitle == "第二章")
    #expect(model.headerSummary.readingProgressText == "第二章")
}

/// Builds a `ForumDependencies` package backed by isolated per-test stores.
/// Factories for repositories this file never exercises trap loudly.
@MainActor
private func makeForumDetailDependencies(
    contentCoverStore: ContentCoverStore? = nil,
    readingProgressStore: ReadingProgressStore? = nil
) throws -> ForumDependencies {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-deps")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let session = YamiboNetworkConfiguration.makeSession()
    @Sendable func makeClient() async -> YamiboClient {
        let sessionState = await sessionStore.load()
        return YamiboClient(
            session: session,
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
        )
    }
    let forumCacheStore = ForumCacheStore(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    return ForumDependencies(
        sessionStore: sessionStore,
        profileStore: YamiboProfileStore(defaults: defaults, key: "profile"),
        localFavoriteLibraryStore: FavoriteLibraryStore(defaults: defaults, key: "local-favorites"),
        readingProgressStore: readingProgressStore ?? ReadingProgressStore(defaults: defaults, key: "reading-progress"),
        settingsStore: SettingsStore(defaults: defaults, key: "settings"),
        contentCoverStore: contentCoverStore ?? ContentCoverStore(defaults: defaults, key: "content-covers"),
        mangaDirectoryStore: ForumDetailTestsUnusedMangaDirectoryStore(),
        mangaDirectorySearchCooldownState: MangaDirectorySearchCooldownState(),
        makeForumRepository: { ForumRepository(client: await makeClient(), cacheStore: forumCacheStore) },
        makeForumThreadReaderRepository: { ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore) },
        makeUserSpaceRepository: { UserSpaceRepository(client: await makeClient()) },
        makeBlogReaderRepository: { BlogReaderRepository(client: await makeClient()) },
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) },
        makeNovelReaderRepository: { fatalError("makeNovelReaderRepository is not exercised by ForumNovelDetailViewModelTests") },
        makeMangaReaderProjectionLoader: { fatalError("makeMangaReaderProjectionLoader is not exercised by ForumNovelDetailViewModelTests") },
        makeMangaDirectoryRepository: { fatalError("makeMangaDirectoryRepository is not exercised by ForumNovelDetailViewModelTests") },
        makeThreadRouteResolver: { YamiboThreadRouteResolver(client: await makeClient()) }
    )
}

private struct ForumDetailTestsUnusedMangaDirectoryStore: MangaDirectoryPersisting {
    func directory(named name: String) async throws -> MangaDirectory? { nil }
    func directory(containingTID tid: String) async throws -> MangaDirectory? { nil }
    func saveDirectory(_ directory: MangaDirectory) async throws {}
    func deleteDirectory(named name: String) async throws {}
}

@MainActor
private func makeForumNovelDetailViewModel(
    dependencies: ForumDependencies? = nil,
    documentLoader: (any ForumNovelDocumentLoading)? = nil,
    threadPageLoader: (any ForumNovelThreadPageLoading)? = nil,
    authorID: String? = "42"
) throws -> ForumNovelDetailViewModel {
    let resolvedDependencies = try dependencies ?? makeForumDetailDependencies()
    let novelRepositoryProvider: (@Sendable () async -> any ForumNovelDocumentLoading)? = documentLoader.map { loader in
        { @Sendable in loader }
    }
    let threadRepositoryProvider: (@Sendable () async -> any ForumNovelThreadPageLoading)? = threadPageLoader.map { loader in
        { @Sendable in loader }
    }
    return ForumNovelDetailViewModel(
        context: NovelDetailLaunchContext(
            thread: ThreadIdentity(tid: "900", fid: "49"),
            title: "小说标题",
            authorID: authorID
        ),
        dependencies: resolvedDependencies,
        novelRepositoryProvider: novelRepositoryProvider,
        threadRepositoryProvider: threadRepositoryProvider
    )
}

private func makeNovelDetailThreadPage(
    page: Int,
    totalPages: Int,
    postID: String,
    chapterTitle: String
) throws -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: "900", fid: "49"),
        title: "小说标题",
        posts: [
            ForumThreadPost(
                postID: postID,
                floorText: page == 1 ? "楼主" : "\(page)#",
                author: BlogReaderUser(uid: "42", name: "楼主名", avatarURL: nil),
                contentHTML: "",
                contentText: "\(chapterTitle)\n正文",
                contentBlocks: []
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: page, totalPages: totalPages)
    )
}

private struct FakeForumNovelDocumentLoader: ForumNovelDocumentLoading {
    func loadPage(_ request: NovelPageRequest) async throws -> NovelReaderProjection {
        NovelReaderProjection(
            threadID: request.threadID,
            view: request.view,
            maxView: 1,
            resolvedAuthorID: request.authorID,
            segments: [
                .text("第一章\n正文", chapterTitle: "第一章")
            ]
        )
    }
}

private struct FailingForumNovelDocumentLoader: ForumNovelDocumentLoading {
    let error: Error

    func loadPage(_: NovelPageRequest) async throws -> NovelReaderProjection {
        throw error
    }
}

private final class FakeForumNovelThreadPageLoader: ForumNovelThreadPageLoading, @unchecked Sendable {
    private let pages: [Int: ForumThreadPage]
    private var cachedPages: [Int: ForumThreadPage]
    private var failuresByPage: [Int: [Error]]
    private var recordedCachedNovelPages: [Int] = []
    private var recordedNovelFetches: [Int] = []
    private var recordedThreadFetches: [ForumNovelThreadPageFetch] = []
    private var recordedClearedThreads: [ThreadIdentity] = []
    private var recordedStoredPages: [ForumNovelThreadPageStore] = []

    init(
        pages: [Int: ForumThreadPage],
        cachedPages: [Int: ForumThreadPage] = [:],
        failuresByPage: [Int: [Error]] = [:]
    ) {
        self.pages = pages
        self.cachedPages = cachedPages
        self.failuresByPage = failuresByPage
    }

    func cachedNovelThreadPage(context _: NovelDetailLaunchContext, page: Int) async -> ForumThreadPage? {
        recordedCachedNovelPages.append(page)
        return cachedPages[page]
    }

    func fetchNovelThreadPage(context _: NovelDetailLaunchContext, page: Int) async throws -> ForumThreadPage {
        recordedNovelFetches.append(page)
        if var failures = failuresByPage[page], !failures.isEmpty {
            let failure = failures.removeFirst()
            failuresByPage[page] = failures
            throw failure
        }
        guard let pageDocument = pages[page] else {
            throw FakeForumNovelThreadPageLoaderError.missingPage(page: page)
        }
        return pageDocument
    }

    func clearCachedThreadPages(thread: ThreadIdentity) async throws {
        cachedPages.removeAll()
        recordedClearedThreads.append(thread)
    }

    func storeNovelThreadPage(_ pageDocument: ForumThreadPage, context: NovelDetailLaunchContext, pageNumber: Int) async throws {
        cachedPages[pageNumber] = pageDocument
        recordedStoredPages.append(
            ForumNovelThreadPageStore(
                authorID: context.authorID,
                page: pageNumber,
                title: pageDocument.title
            )
        )
    }

    func fetchThreadPage(
        thread _: ThreadIdentity,
        title _: String,
        authorID: String?,
        page: Int
    ) async throws -> ForumThreadPage {
        recordedThreadFetches.append(ForumNovelThreadPageFetch(authorID: authorID, page: page))
        guard let pageDocument = pages[page] else {
            throw FakeForumNovelThreadPageLoaderError.missingPage(page: page)
        }
        return pageDocument
    }

    func threadFetchCalls() -> [ForumNovelThreadPageFetch] {
        recordedThreadFetches
    }

    func novelFetchCalls() -> [Int] {
        recordedNovelFetches
    }

    func cachedNovelCalls() -> [Int] {
        recordedCachedNovelPages
    }

    func clearedThreadIDs() -> [String] {
        recordedClearedThreads.map(\.tid)
    }

    func storedPages() -> [ForumNovelThreadPageStore] {
        recordedStoredPages
    }
}

private enum FakeForumNovelThreadPageLoaderError: Error {
    case missingPage(page: Int)
    case plannedFailure(page: Int)
}

private struct ForumNovelThreadPageFetch: Equatable {
    var authorID: String?
    var page: Int
}

private struct ForumNovelThreadPageStore: Equatable {
    var authorID: String?
    var page: Int
    var title: String
}
