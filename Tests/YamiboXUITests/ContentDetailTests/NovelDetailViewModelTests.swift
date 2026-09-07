import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Test func novelDetailContinueStartsAtFirstViewWithoutHistory() throws {
    let model = try makeNovelDetailViewModel()

    let context = model.continueLaunchContext()

    #expect(context.source == .forum)
    #expect(context.initialView == 1)
    #expect(context.initialResumePoint == nil)
    #expect(context.authorID == "42")
}

@MainActor
@Test func novelDetailContinueUsesReadingProgressResumePointWhenAvailable() throws {
    let model = try makeNovelDetailViewModel()
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
@Test func novelDetailContinueUsesIndependentReadingProgressWithoutFavorite() throws {
    let model = try makeNovelDetailViewModel()
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
@Test func novelDetailContinueUsesStoredChapterReadingProgress() throws {
    let model = try makeNovelDetailViewModel()
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
@Test func novelDetailHeaderSummaryUsesThreadPageCoverCandidateWhenPersistedCoverMissing() throws {
    let model = try makeNovelDetailViewModel()
    let ignoredURL = try #require(URL(string: "https://bbs.yamibo.com/static/image/smiley/default/none.gif"))
    let coverURL = try #require(URL(string: "https://bbs.yamibo.com/data/attachment/forum/cover.jpg"))
    model.chapters = [
        NovelChapterSummary(id: "1|序章", title: "序章", view: 1),
        NovelChapterSummary(id: "1|第一章", title: "第一章", view: 1)
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
@Test func novelDetailUsesSanitizedDiscuzTitle() throws {
    let model = try makeNovelDetailViewModel()
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
@Test func novelDetailHeaderFallsBackToPostedAtForLastUpdatedText() throws {
    let model = try makeNovelDetailViewModel()
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
@Test func novelDetailHeaderPrefersPersistedContentCover() async throws {
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
    let dependencies = try makeNovelDetailDependencies(contentCoverStore: coverStore)
    let model = try makeNovelDetailViewModel(dependencies: dependencies)
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
@Test func novelDetailReloadStoresInitialPageCoverWithoutRefetchingThreadPage() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-initial-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeNovelDetailDependencies(contentCoverStore: coverStore)
    let initialImage = try #require(URL(string: "https://img.example.com/initial-owner.jpg"))
    let threadPageLoader = FakeNovelThreadPageLoader(pages: [
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
    let model = try makeNovelDetailViewModel(
        dependencies: dependencies,
        documentLoader: FakeNovelDocumentLoader(),
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
@Test func novelDetailReloadUsesCachedInitialThreadPageWithoutFetching() async throws {
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
    let threadPageLoader = FakeNovelThreadPageLoader(pages: [:], cachedPages: [1: cachedPage])
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
        threadPageLoader: threadPageLoader
    )

    await model.reload()

    #expect(model.headerSummary.title == "缓存小说标题")
    #expect(model.chapters.map(\.title) == ["缓存首楼"])
    #expect(threadPageLoader.cachedNovelCalls() == [1])
    #expect(threadPageLoader.novelFetchCalls().isEmpty)
}

@MainActor
@Test func novelDetailReloadKeepsCachedInitialThreadPageWhenReaderDocumentTimesOut() async throws {
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
    let threadPageLoader = FakeNovelThreadPageLoader(pages: [:], cachedPages: [1: cachedPage])
    let model = try makeNovelDetailViewModel(
        documentLoader: FailingNovelDocumentLoader(error: URLError(.timedOut)),
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
@Test func novelDetailLoadChapterSectionUsesCachedThreadPageWithoutFetching() async throws {
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
    let threadPageLoader = FakeNovelThreadPageLoader(
        pages: [:],
        cachedPages: [
            1: firstPage,
            2: secondPage
        ]
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
        threadPageLoader: threadPageLoader
    )

    await model.reload()
    await model.loadChapterSection(page: 2)

    #expect(model.chapterSections.flatMap(\.chapters).map(\.title).contains("第二章"))
    #expect(threadPageLoader.cachedNovelCalls() == [1, 2])
    #expect(threadPageLoader.novelFetchCalls().isEmpty)
}

@MainActor
@Test func novelDetailRefreshContentCoverStoresOwnerPostCandidateOnly() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-auto-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeNovelDetailDependencies(contentCoverStore: coverStore)
    let model = try makeNovelDetailViewModel(dependencies: dependencies)
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
@Test func novelDetailRefreshContentCoverDoesNotStoreWithoutFirstFloorOwner() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-cover-no-owner")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeNovelDetailDependencies(contentCoverStore: coverStore)
    let model = try makeNovelDetailViewModel(dependencies: dependencies)
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
@Test func novelDetailReloadDoesNotScanLaterThreadPagesForCover() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-later-cover")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let coverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "content-covers"
    )
    let dependencies = try makeNovelDetailDependencies(contentCoverStore: coverStore)
    let threadPageLoader = FakeNovelThreadPageLoader(pages: [
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
    let model = try makeNovelDetailViewModel(
        dependencies: dependencies,
        documentLoader: FakeNovelDocumentLoader(),
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
@Test func novelDetailReusesLoadedChapterPagesUntilReload() async throws {
    let firstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "第一章")
    let secondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "第二章")
    let loader = FakeNovelThreadPageLoader(pages: [
        1: firstPage,
        2: secondPage
    ])
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
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
@Test func novelDetailRefreshBypassesCacheClearsPersistentPagesAndReloadsFirstPage() async throws {
    let cachedFirstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "缓存第一章")
    let cachedSecondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "缓存第二章")
    let freshFirstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "刷新第一章")
    let freshSecondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "刷新第二章")
    let loader = FakeNovelThreadPageLoader(
        pages: [
            1: freshFirstPage,
            2: freshSecondPage
        ],
        cachedPages: [
            1: cachedFirstPage,
            2: cachedSecondPage
        ]
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
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
        NovelThreadPageStore(authorID: "42", page: 1, title: "小说标题")
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
@Test func novelDetailRefreshCompletesCacheWritesAfterGestureCancellationAndCanRefreshAgain() async throws {
    let cached = try makeNovelDetailThreadPage(page: 1, totalPages: 1, postID: "1001", chapterTitle: "缓存章节")
    let fresh = try makeNovelDetailThreadPage(page: 1, totalPages: 1, postID: "1001", chapterTitle: "新章节")
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer {
        started.continuation.finish()
        release.continuation.finish()
    }
    let loader = FakeNovelThreadPageLoader(
        pages: [1: fresh], cachedPages: [1: cached],
        beforeFetch: {
            started.continuation.yield(())
            // Like completeStartedRequest, this fetch can return a page even
            // if the caller was cancelled. The cache operations still check.
            for await _ in release.stream { break }
        }
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(), threadPageLoader: loader
    )
    await model.reload()

    let refresh = Task { await model.refresh() }
    for await _ in started.stream { break }
    await model.reload()
    #expect(model.isLoading)
    #expect(loader.cachedNovelCalls() == [1])
    refresh.cancel()
    release.continuation.finish()
    await refresh.value

    #expect(model.chapters.map(\.title) == ["新章节"])
    #expect(loader.clearedThreadIDs() == ["900"])
    #expect(loader.storedPages().count == 1)
    #expect(model.favoriteActions.transientMessage == nil)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)

    await model.refresh()
    #expect(loader.novelFetchCalls() == [1, 1])
    #expect(loader.storedPages().count == 2)
    #expect(model.favoriteActions.transientMessage == nil)
    #expect(!model.isLoading)
}

@MainActor
@Test(arguments: [0, 1, 2])
func novelDetailCancelledRefreshPreservesContentWithoutFailureToast(cancellationKind: Int) async throws {
    let firstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "第一章")
    let secondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "第二章")
    let failure: any Error
    switch cancellationKind {
    case 0: failure = CancellationError()
    case 1: failure = URLError(.cancelled)
    default: failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    }
    let loader = FakeNovelThreadPageLoader(
        pages: [1: firstPage, 2: secondPage], cachedPages: [1: firstPage, 2: secondPage],
        failuresByPage: [1: [failure]]
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(), threadPageLoader: loader
    )
    await model.reload()
    await model.toggleChapterSection(page: 2)
    // Observe the real preload instead of racing it with a manually assigned document.
    for _ in 0..<100 where model.document == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let previousDocument = try #require(model.document)
    let previousSections = model.chapterSections.map(\.chapters)

    await model.refresh()

    #expect(model.errorMessage == nil)
    #expect(model.favoriteActions.transientMessage == nil)
    #expect(model.document == previousDocument)
    #expect(model.chapterSections.map(\.chapters) == previousSections)
    #expect(model.expandedChapterPages == [1, 2])
    #expect(!model.isLoading)
    #expect(loader.clearedThreadIDs().isEmpty)
    #expect(loader.storedPages().isEmpty)
}

@MainActor
@Test func novelDetailRefreshFailurePreservesExistingContentAndShowsTransientMessage() async throws {
    let cachedFirstPage = try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "缓存第一章")
    let cachedSecondPage = try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "缓存第二章")
    let loader = FakeNovelThreadPageLoader(
        pages: [
            1: cachedFirstPage,
            2: cachedSecondPage
        ],
        cachedPages: [
            1: cachedFirstPage,
            2: cachedSecondPage
        ],
        failuresByPage: [
            1: [FakeNovelThreadPageLoaderError.plannedFailure(page: 1)]
        ]
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.reload()
    await model.toggleChapterSection(page: 2)
    await model.refresh()

    #expect(model.errorMessage == nil)
    #expect(model.favoriteActions.transientMessage == L10n.string("forum.novel_detail.refresh_failed", FakeNovelThreadPageLoaderError.plannedFailure(page: 1).localizedDescription))
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[0].chapters.map(\.title) == ["缓存第一章"])
    #expect(model.chapterSections[1].chapters.map(\.title) == ["缓存第二章"])
    #expect(loader.clearedThreadIDs().isEmpty)
    #expect(loader.storedPages().isEmpty)
}

@MainActor
@Test func novelDetailRefreshFailureWithoutExistingContentUsesPageError() async throws {
    let loader = FakeNovelThreadPageLoader(
        pages: [:],
        failuresByPage: [
            1: [FakeNovelThreadPageLoaderError.plannedFailure(page: 1)]
        ]
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.refresh()

    #expect(model.threadPage == nil)
    #expect(model.chapters.isEmpty)
    #expect(model.favoriteActions.transientMessage == nil)
    #expect(model.errorMessage == FakeNovelThreadPageLoaderError.plannedFailure(page: 1).localizedDescription)
}

@MainActor
@Test func novelDetailKnownAuthorLoadsInitialPageOnce() async throws {
    let loader = FakeNovelThreadPageLoader(pages: [
        1: try makeNovelDetailThreadPage(page: 1, totalPages: 1, postID: "1001", chapterTitle: "第一章")
    ])
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
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
@Test func novelDetailOfflineMetadataFailureStillOffersTheSavedReaderPosition() async throws {
    let dependencies = try makeNovelDetailDependencies()
    try await dependencies.readingProgressStore.saveNovel(
        NovelReadingPosition(threadID: "900", view: 6, authorID: "42")
    )
    let model = try makeNovelDetailViewModel(
        dependencies: dependencies,
        documentLoader: FakeNovelDocumentLoader(),
        threadPageLoader: FakeNovelThreadPageLoader(pages: [:], failuresByPage: [1: [URLError(.notConnectedToInternet)]])
    )

    await model.load()

    #expect(model.errorMessage != nil)
    #expect(!model.isLoading)
    let context = model.continueLaunchContext()
    #expect(context.threadID == "900")
    #expect(context.initialView == 6)
    #expect(context.authorID == "42")
}

@MainActor
@Test func novelDetailMissingAuthorDiscoversAuthorBeforeLoadingContent() async throws {
    let loader = FakeNovelThreadPageLoader(pages: [
        1: try makeNovelDetailThreadPage(page: 1, totalPages: 1, postID: "1001", chapterTitle: "第一章")
    ])
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
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
@Test func novelDetailDoesNotCacheFailedChapterPageLoads() async throws {
    let loader = FakeNovelThreadPageLoader(
        pages: [
            1: try makeNovelDetailThreadPage(page: 1, totalPages: 2, postID: "1001", chapterTitle: "第一章"),
            2: try makeNovelDetailThreadPage(page: 2, totalPages: 2, postID: "2001", chapterTitle: "第二章")
        ],
        failuresByPage: [
            2: [FakeNovelThreadPageLoaderError.plannedFailure(page: 2)]
        ]
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(),
        threadPageLoader: loader
    )

    await model.reload()
    await model.toggleChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2])
    #expect(model.expandedChapterPages == [1, 2])
    #expect(model.chapterSections[1].isLoaded == false)
    #expect(model.chapterSections[1].errorMessage != nil)
    #expect(model.chapterSections[1].errorDetails?.summary == FakeNovelThreadPageLoaderError.plannedFailure(page: 2).localizedDescription)
    #expect(model.chapterSections[1].chapters.isEmpty)

    await model.loadChapterSection(page: 2)

    #expect(loader.novelFetchCalls() == [1, 2, 2])
    #expect(model.chapterSections[1].isLoaded)
    #expect(model.chapterSections[1].errorMessage == nil)
    #expect(model.chapterSections[1].errorDetails == nil)
    #expect(model.chapterSections[1].chapters.map(\.title) == ["第二章"])
}

@MainActor
@Test func novelDetailConcurrentChapterFailuresKeepSeparateDiagnostics() async throws {
    let loader = ConcurrentFailingChapterLoader(
        firstPage: try makeNovelDetailThreadPage(page: 1, totalPages: 3, postID: "1001", chapterTitle: "第一章")
    )
    let model = try makeNovelDetailViewModel(
        documentLoader: FakeNovelDocumentLoader(), threadPageLoader: loader
    )
    await model.reload()
    async let second: Void = model.loadChapterSection(page: 2)
    async let third: Void = model.loadChapterSection(page: 3)
    _ = await (second, third)
    #expect(model.chapterSections[1].errorDetails?.causes.first?.code == URLError.timedOut.rawValue)
    #expect(model.chapterSections[2].errorDetails?.causes.first?.code == URLError.notConnectedToInternet.rawValue)
    #expect(model.chapterSections[0].errorDetails == nil)
}

@MainActor
@Test func novelDetailGroupsChapterDirectoryByThreadPage() throws {
    let model = try makeNovelDetailViewModel()
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

    let sections = NovelDetailViewModel.chapterSections(
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
@Test func novelDetailChapterTapUsesPostResumePoint() throws {
    let model = try makeNovelDetailViewModel()
    let section = NovelDetailViewModel.chapterSections(
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
@Test func novelDetailChapterDirectoryUsesReaderAuthorReplyVisibilitySetting() throws {
    let model = try makeNovelDetailViewModel()
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

    let sections = NovelDetailViewModel.chapterSections(
        from: [1: page],
        totalPages: 1,
        novelReaderSettings: NovelReaderAppearanceSettings(showsAuthorRepliesToOthers: false)
    )

    #expect(sections[0].chapters.map(\.title) == ["第一章", "第二章"])
    #expect(sections[0].chapters.map(\.postID) == ["1001", "1003"])
}

@MainActor
@Test func novelDetailChapterTitleUsesReaderParserTitle() throws {
    let model = try makeNovelDetailViewModel()
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

    let sections = NovelDetailViewModel.chapterSections(from: [1: page], totalPages: 1)

    #expect(sections[0].chapters.map(\.title) == ["引用里的旧标题"])
}

@MainActor
@Test func novelDetailMarksCurrentReadChapterFromReadingProgressResumePoint() throws {
    let model = try makeNovelDetailViewModel()
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

    let sections = NovelDetailViewModel.chapterSections(
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
@Test func novelDetailMarksOnlyIdentityMatchedFloorWhenChapterTitlesDuplicate() throws {
    let model = try makeNovelDetailViewModel()
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

    let sections = NovelDetailViewModel.chapterSections(
        from: [1: firstPage],
        totalPages: 1,
        readingProgress: model.readingProgress,
        favorite: model.favoriteActions.favorite
    )

    #expect(sections[0].chapters.map(\.title) == ["喜歡的人和義妹", "喜歡的人和義妹", "喜歡的人和義妹"])
    #expect(sections[0].chapters.map(\.isCurrentRead) == [false, true, false])
}

@MainActor
@Test func novelDetailTitleFallbackMarksOnlyFirstDuplicateWhenNoResumePointIdentityExists() throws {
    let model = try makeNovelDetailViewModel()
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

    let sections = NovelDetailViewModel.chapterSections(
        from: [1: firstPage],
        totalPages: 1,
        readingProgress: model.readingProgress,
        favorite: model.favoriteActions.favorite
    )

    #expect(sections[0].chapters.map(\.isCurrentRead) == [true, false, false])
}

@MainActor
@Test func novelDetailRefreshesReadingProgressWhenReadingProgressStoreChanges() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "novel-detail-progress-refresh")
    _ = try YamiboTestDefaults.make(suiteName: suiteName)
    let readingProgressStore = ReadingProgressStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "reading-progress"
    )
    let dependencies = try makeNovelDetailDependencies(
        contentCoverStore: ContentCoverStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "content-covers"
        ),
        readingProgressStore: readingProgressStore
    )
    let model = try makeNovelDetailViewModel(dependencies: dependencies)
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

/// Builds a `NovelDetailDependencies` package backed by isolated per-test stores.
/// Factories for repositories this file never exercises trap loudly.
@MainActor
private func makeNovelDetailDependencies(
    contentCoverStore: ContentCoverStore? = nil,
    readingProgressStore: ReadingProgressStore? = nil
) throws -> NovelDetailDependencies {
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
    return NovelDetailDependencies(
        localFavoriteLibraryStore: FavoriteLibraryStore(defaults: defaults, key: "local-favorites"),
        readingProgressStore: readingProgressStore ?? ReadingProgressStore(defaults: defaults, key: "reading-progress"),
        settingsStore: SettingsStore(defaults: defaults, key: "settings"),
        contentCoverStore: contentCoverStore ?? ContentCoverStore(defaults: defaults, key: "content-covers"),
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) },
        makeNovelReaderRepository: { fatalError("makeNovelReaderRepository is not exercised by NovelDetailViewModelTests") },
        makeForumThreadReaderRepository: { ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore) }
    )
}

@MainActor
private func makeNovelDetailViewModel(
    dependencies: NovelDetailDependencies? = nil,
    documentLoader: (any NovelDetailDocumentLoading)? = nil,
    threadPageLoader: (any NovelDetailThreadPageLoading)? = nil,
    authorID: String? = "42"
) throws -> NovelDetailViewModel {
    let resolvedDependencies = try dependencies ?? makeNovelDetailDependencies()
    let novelRepositoryProvider: (@Sendable () async -> any NovelDetailDocumentLoading)? = documentLoader.map { loader in
        { @Sendable in loader }
    }
    let threadRepositoryProvider: (@Sendable () async -> any NovelDetailThreadPageLoading)? = threadPageLoader.map { loader in
        { @Sendable in loader }
    }
    return NovelDetailViewModel(
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

private struct FakeNovelDocumentLoader: NovelDetailDocumentLoading {
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

private struct ConcurrentFailingChapterLoader: NovelDetailThreadPageLoading {
    let firstPage: ForumThreadPage

    func cachedNovelThreadPage(context: NovelDetailLaunchContext, page: Int) async -> ForumThreadPage? { nil }
    func clearCachedThreadPages(thread: ThreadIdentity) async throws {}
    func storeNovelThreadPage(_ page: ForumThreadPage, context: NovelDetailLaunchContext, pageNumber: Int) async throws {}

    func fetchNovelThreadPage(context: NovelDetailLaunchContext, page: Int) async throws -> ForumThreadPage {
        if page == 1 { return firstPage }
        await Task.yield()
        throw URLError(page == 2 ? .timedOut : .notConnectedToInternet)
    }
}

private struct FailingNovelDocumentLoader: NovelDetailDocumentLoading {
    let error: Error

    func loadPage(_: NovelPageRequest) async throws -> NovelReaderProjection {
        throw error
    }
}

private final class FakeNovelThreadPageLoader: NovelDetailThreadPageLoading, @unchecked Sendable {
    private let pages: [Int: ForumThreadPage]
    private let beforeFetch: (@Sendable () async -> Void)?
    private var cachedPages: [Int: ForumThreadPage]
    private var failuresByPage: [Int: [Error]]
    private var recordedCachedNovelPages: [Int] = []
    private var recordedNovelFetches: [Int] = []
    private var recordedThreadFetches: [NovelThreadPageFetch] = []
    private var recordedClearedThreads: [ThreadIdentity] = []
    private var recordedStoredPages: [NovelThreadPageStore] = []

    init(
        pages: [Int: ForumThreadPage],
        cachedPages: [Int: ForumThreadPage] = [:],
        failuresByPage: [Int: [Error]] = [:],
        beforeFetch: (@Sendable () async -> Void)? = nil
    ) {
        self.pages = pages
        self.cachedPages = cachedPages
        self.failuresByPage = failuresByPage
        self.beforeFetch = beforeFetch
    }

    func cachedNovelThreadPage(context _: NovelDetailLaunchContext, page: Int) async -> ForumThreadPage? {
        recordedCachedNovelPages.append(page)
        return cachedPages[page]
    }

    func fetchNovelThreadPage(context _: NovelDetailLaunchContext, page: Int) async throws -> ForumThreadPage {
        recordedNovelFetches.append(page)
        await beforeFetch?()
        if var failures = failuresByPage[page], !failures.isEmpty {
            let failure = failures.removeFirst()
            failuresByPage[page] = failures
            throw failure
        }
        guard let pageDocument = pages[page] else {
            throw FakeNovelThreadPageLoaderError.missingPage(page: page)
        }
        return pageDocument
    }

    func clearCachedThreadPages(thread: ThreadIdentity) async throws {
        try Task.checkCancellation()
        cachedPages.removeAll()
        recordedClearedThreads.append(thread)
    }

    func storeNovelThreadPage(_ pageDocument: ForumThreadPage, context: NovelDetailLaunchContext, pageNumber: Int) async throws {
        try Task.checkCancellation()
        cachedPages[pageNumber] = pageDocument
        recordedStoredPages.append(
            NovelThreadPageStore(
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
        recordedThreadFetches.append(NovelThreadPageFetch(authorID: authorID, page: page))
        guard let pageDocument = pages[page] else {
            throw FakeNovelThreadPageLoaderError.missingPage(page: page)
        }
        return pageDocument
    }

    func threadFetchCalls() -> [NovelThreadPageFetch] {
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

    func storedPages() -> [NovelThreadPageStore] {
        recordedStoredPages
    }
}

private enum FakeNovelThreadPageLoaderError: Error {
    case missingPage(page: Int)
    case plannedFailure(page: Int)
}

private struct NovelThreadPageFetch: Equatable {
    var authorID: String?
    var page: Int
}

private struct NovelThreadPageStore: Equatable {
    var authorID: String?
    var page: Int
    var title: String
}
