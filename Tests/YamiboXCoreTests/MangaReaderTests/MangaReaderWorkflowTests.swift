import Foundation
import Testing
@testable import YamiboXCore

@MainActor
@Suite("MangaReaderTests: Workflow")
struct MangaReaderTestsWorkflow {
    @Test func workflowStartsLoadingAndPublishesLoadedPresentation() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let seed = makeWorkflowSeed(currentTID: "700", tagIDs: ["12"])
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(output: .seed(seed))
        let store = RecordingMangaDirectoryStore()
        let context = try makeWorkflowContext(tid: "700", initialPage: 1)
        let workflow = MangaReaderWorkflow(
            context: context,
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        #expect(workflow.presentation == MangaReaderPresentation(
            state: .loading(MangaReaderLoadingPresentation(title: "测试漫画"))
        ))

        let presentation = await workflow.prepare()

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.title == "测试漫画")
        #expect(loaded.directoryTitle == "测试漫画")
        #expect(loaded.pages.map(\.id) == ["700#0", "700#1"])
        #expect(loaded.currentPage?.id == "700#1")
        #expect(loaded.currentPageIndex == 1)
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
        #expect(await loader.loadedThreadIDs == [context.chapterTID])
        #expect(await repository.seedThreadIDs == [context.chapterTID])
        #expect(await store.savedDirectories.count == 1)
    }

    // Smart Comic Mode off (smart-comic-mode design decision #12): the
    // workflow must skip `resolveInitialDirectory` entirely rather than
    // resolve-then-ignore, and fall back to a single-chapter pseudo
    // directory with no siblings.
    @Test func workflowSkipsDirectoryResolutionWhenSmartModeIsDisabled() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(
            output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
        )
        let store = RecordingMangaDirectoryStore()
        let context = try makeWorkflowContext(tid: "700", initialPage: 1, isSmartModeEnabled: false)
        let workflow = MangaReaderWorkflow(
            context: context,
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        let presentation = await workflow.prepare()

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.directoryTitle == "测试漫画")
        #expect(loaded.pages.map(\.id) == ["700#0", "700#1"])
        #expect(loaded.currentPage?.id == "700#1")
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
        // No directory-related network/persistence activity at all — not
        // resolved-then-discarded, never called.
        #expect(await repository.seedThreadIDs.isEmpty)
        #expect(await store.requestedNames.isEmpty)
        #expect(await store.requestedTIDs.isEmpty)
        #expect(await store.savedDirectories.isEmpty)
        // The pseudo-directory has no siblings, so chapter-jump affordances
        // are naturally unavailable without any extra gating.
        #expect(workflow.canJumpToAdjacentChapter(from: loaded.readingPosition, delta: 1) == false)
        #expect(workflow.canJumpToAdjacentChapter(from: loaded.readingPosition, delta: -1) == false)
    }

    @Test func initialPageIsClampedThroughChapterWindow() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let seed = makeWorkflowSeed(currentTID: "700", tagIDs: ["12"])
        let presentation = await makeLoadedPresentation(
            context: try makeWorkflowContext(tid: "700", initialPage: 99),
            document: document,
            seed: seed
        )

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.currentPage?.id == "700#1")
        #expect(loaded.currentPageIndex == 1)
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
    }

    @Test func workflowMovesReadingPositionInMemoryByLoadedPageIndex() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 3)
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(
            output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
        )
        let store = RecordingMangaDirectoryStore()
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 0),
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        _ = await workflow.prepare()
        let presentation = workflow.moveToLoadedPage(at: 2)

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.currentPage?.id == "700#2")
        #expect(loaded.currentPageIndex == 2)
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 2))
        #expect(await store.savedDirectories.count == 1)
        #expect(await store.deletedNames.isEmpty)
    }

    @Test func workflowRefreshesViewportPlacementFromCurrentPageWhenPagedTurnStyleChanges() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 13)
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 11),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: RecordingMangaDirectoryRepository(
                output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
            ),
            directoryStore: RecordingMangaDirectoryStore(),
            settings: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .slide)
        )

        _ = await workflow.prepare()
        let initialLoaded = try #require(loadedPresentation(in: workflow.presentation))
        let initialRevision = try #require(initialLoaded.viewportPlacement?.revision)
        _ = workflow.moveToLoadedPage(at: 12)
        let movedLoaded = try #require(loadedPresentation(in: workflow.presentation))
        #expect(movedLoaded.currentPageIndex == 12)
        #expect(movedLoaded.viewportPlacement == nil)

        var pageCurlSettings = workflow.presentation.settings
        pageCurlSettings.pagedTurnStyle = .pageCurl
        let pageCurlPresentation = workflow.applySettings(pageCurlSettings)
        let pageCurlLoaded = try #require(loadedPresentation(in: pageCurlPresentation))
        let pageCurlRevision = try #require(pageCurlLoaded.viewportPlacement?.revision)

        #expect(pageCurlLoaded.currentPageIndex == 12)
        #expect(pageCurlLoaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 12))
        #expect(pageCurlLoaded.viewportPlacement?.targetPageIndex == 12)
        #expect(pageCurlRevision == initialRevision + 1)

        var slideSettings = pageCurlPresentation.settings
        slideSettings.pagedTurnStyle = .slide
        let slidePresentation = workflow.applySettings(slideSettings)
        let slideLoaded = try #require(loadedPresentation(in: slidePresentation))

        #expect(slideLoaded.currentPageIndex == 12)
        #expect(slideLoaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 12))
        #expect(slideLoaded.viewportPlacement?.targetPageIndex == 12)
        #expect(slideLoaded.viewportPlacement?.revision == pageCurlRevision + 1)
    }

    @Test func workflowKeepsViewportPlacementRevisionForNonViewportSettingsChanges() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 1),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: RecordingMangaDirectoryRepository(
                output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
            ),
            directoryStore: RecordingMangaDirectoryStore(),
            settings: MangaReaderSettings(readingMode: .paged, pagedTurnStyle: .slide)
        )

        _ = await workflow.prepare()
        let initialLoaded = try #require(loadedPresentation(in: workflow.presentation))
        let initialRevision = try #require(initialLoaded.viewportPlacement?.revision)

        var brightnessSettings = workflow.presentation.settings
        brightnessSettings.brightness = 0.75
        let brightnessPresentation = workflow.applySettings(brightnessSettings)
        let brightnessLoaded = try #require(loadedPresentation(in: brightnessPresentation))

        #expect(brightnessLoaded.viewportPlacement?.targetPageIndex == 1)
        #expect(brightnessLoaded.viewportPlacement?.revision == initialRevision)

        var sortSettings = brightnessPresentation.settings
        sortSettings.directorySortOrder = .descending
        let sortPresentation = workflow.applySettings(sortSettings)
        let sortLoaded = try #require(loadedPresentation(in: sortPresentation))

        #expect(sortLoaded.viewportPlacement?.targetPageIndex == 1)
        #expect(sortLoaded.viewportPlacement?.revision == initialRevision)
        #expect(sortLoaded.directoryPanel.sortOrder == .descending)
    }

    @Test func workflowClampsMovedReadingPositionThroughChapterWindow() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 0),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: RecordingMangaDirectoryRepository(
                output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
            ),
            directoryStore: RecordingMangaDirectoryStore()
        )

        _ = await workflow.prepare()
        guard case let .loaded(firstPage) = workflow.moveToLoadedPage(at: -10).state,
              case let .loaded(lastPage) = workflow.moveToLoadedPage(at: 99).state else {
            Issue.record("Expected loaded presentations")
            return
        }

        #expect(firstPage.currentPage?.id == "700#0")
        #expect(firstPage.currentPageIndex == 0)
        #expect(firstPage.readingPosition == MangaReadingPosition(tid: "700", localIndex: 0))
        #expect(lastPage.currentPage?.id == "700#1")
        #expect(lastPage.currentPageIndex == 1)
        #expect(lastPage.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
    }

    @Test func workflowJumpToPositionClampsLoadedChapterPosition() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 0),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: RecordingMangaDirectoryRepository(
                output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
            ),
            directoryStore: RecordingMangaDirectoryStore()
        )

        _ = await workflow.prepare()
        let presentation = try await workflow.jumpToPosition(MangaReadingPosition(tid: "700", localIndex: 99))
        let loaded = try #require(loadedPresentation(in: presentation))

        #expect(loaded.currentPage?.id == "700#1")
        #expect(loaded.currentPageIndex == 1)
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
    }

    @Test func existingDirectoryNameIsReusedWithoutSeedOrSave() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let existingDirectory = makeWorkflowDirectory(
            name: "本地目录",
            strategy: .searched,
            sourceKey: "local",
            tids: ["999"]
        )
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(
            output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
        )
        let store = RecordingMangaDirectoryStore(directories: [existingDirectory])
        let context = try makeWorkflowContext(
            tid: "700",
            initialPage: 0,
            directoryName: " 本地目录 "
        )
        let workflow = MangaReaderWorkflow(
            context: context,
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        let presentation = await workflow.prepare()

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.directoryTitle == "本地目录")
        #expect(loaded.pages.map(\.id) == ["700#0"])
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 0))
        #expect(await store.requestedNames == ["本地目录"])
        #expect(await store.requestedTIDs.isEmpty)
        #expect(await repository.seedThreadIDs.isEmpty)
        #expect(await store.savedDirectories.isEmpty)
        #expect(await loader.loadedRequests.map(\.offlineOwnerName) == ["本地目录"])
    }

    @Test func existingDirectoryContainingDocumentTIDIsReusedWithoutSeedOrSave() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let existingDirectory = makeWorkflowDirectory(
            name: "本地目录",
            strategy: .searched,
            sourceKey: "local",
            tids: ["700", "701"]
        )
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(output: .failure(.offline))
        let store = RecordingMangaDirectoryStore(directories: [existingDirectory])
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 0),
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        let presentation = await workflow.prepare()

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.directoryTitle == "本地目录")
        #expect(loaded.pages.map(\.id) == ["700#0"])
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 0))
        #expect(await store.requestedNames.isEmpty)
        #expect(await store.requestedTIDs == ["700"])
        #expect(await repository.seedThreadIDs.isEmpty)
        #expect(await store.savedDirectories.isEmpty)
    }

    @Test func existingDirectoryNameMissFallsBackToDirectoryContainingDocumentTID() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let existingDirectory = makeWorkflowDirectory(
            name: "本地目录",
            strategy: .searched,
            sourceKey: "local",
            tids: ["700"]
        )
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(output: .failure(.offline))
        let store = RecordingMangaDirectoryStore(directories: [existingDirectory])
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "Missing"),
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        let presentation = await workflow.prepare()

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.directoryTitle == "本地目录")
        #expect(await store.requestedNames == ["Missing"])
        #expect(await store.requestedTIDs == ["700"])
        #expect(await repository.seedThreadIDs.isEmpty)
        #expect(await store.savedDirectories.isEmpty)
    }

    @Test func directoryNameAndTIDMissInitializesSeedDirectory() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let seed = makeWorkflowSeed(currentTID: "700", tagIDs: ["12"])
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(output: .seed(seed))
        let store = RecordingMangaDirectoryStore()
        let context = try makeWorkflowContext(tid: "700", directoryName: "Missing")
        let workflow = MangaReaderWorkflow(
            context: context,
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        let presentation = await workflow.prepare()

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.directoryTitle == "测试漫画")
        #expect(await store.requestedNames == ["Missing"])
        #expect(await store.requestedTIDs == ["700"])
        #expect(await repository.seedThreadIDs == [context.chapterTID])
        #expect(await store.savedDirectories.count == 1)
    }

    @Test func seedDirectoryInitializesTagStrategyAndDoesNotLoadRemoteDirectory() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let seed = MangaDirectorySeed(
            currentChapter: makeWorkflowChapter(tid: "700", title: "第1话"),
            tagIDs: [" 12 ", "", "12", "34"],
            samePageChapters: [
                makeWorkflowChapter(tid: "700", title: "duplicate"),
                makeWorkflowChapter(tid: "701", title: "第2话")
            ],
            cleanBookName: " 测试漫画 ",
            firstPostID: "9001"
        )
        let loader = RecordingMangaReaderProjectionLoader(output: .document(document))
        let repository = RecordingMangaDirectoryRepository(output: .seed(seed))
        let store = RecordingMangaDirectoryStore()
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700"),
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        _ = await workflow.prepare()

        let saved = try #require(await store.savedDirectories.first)
        #expect(saved.cleanBookName == "测试漫画")
        #expect(saved.strategy == .tag)
        #expect(saved.sourceKey == "12,34")
        #expect(saved.chapters.map(\.tid) == ["700", "701"])
        #expect(await repository.tagDirectoryRequests.isEmpty)
        #expect(await repository.searchRequests.isEmpty)
    }

    @Test func seedDirectoryInitializesLinksStrategy() async throws {
        let seed = MangaDirectorySeed(
            currentChapter: makeWorkflowChapter(tid: "700", title: "第1话"),
            samePageChapters: [makeWorkflowChapter(tid: "701", title: "第2话")],
            cleanBookName: "测试漫画",
            firstPostID: "9001"
        )

        let directory = MangaDirectoryInitialization.directory(from: seed)

        #expect(directory.strategy == .links)
        #expect(directory.sourceKey == "9001")
        #expect(directory.chapters.map(\.tid) == ["700", "701"])
    }

    @Test func seedLinksDirectoryOrdersCurrentChapterWithSamePageChapters() async throws {
        let seed = MangaDirectorySeed(
            currentChapter: makeWorkflowChapter(tid: "526353", title: "与你相恋到生命尽头 23"),
            samePageChapters: [
                makeWorkflowChapter(tid: "525137", title: "22")
            ],
            cleanBookName: "与你相恋到生命尽头",
            firstPostID: "40392543"
        )

        let directory = MangaDirectoryInitialization.directory(from: seed)

        #expect(directory.strategy == .links)
        #expect(directory.chapters.map(\.tid) == ["525137", "526353"])
    }

    @Test func seedDirectoryInitializesPendingSearchStrategy() async throws {
        let seed = MangaDirectorySeed(
            currentChapter: makeWorkflowChapter(tid: "700", title: "第1话"),
            cleanBookName: "测试漫画"
        )

        let directory = MangaDirectoryInitialization.directory(from: seed)

        #expect(directory.strategy == .pendingSearch)
        #expect(directory.sourceKey == "测试漫画")
        #expect(directory.chapters.map(\.tid) == ["700"])
    }

    @Test func seedDirectoryDoesNotTreatDuplicateCurrentLinkAsLinksStrategy() async throws {
        let seed = MangaDirectorySeed(
            currentChapter: makeWorkflowChapter(tid: "700", title: "第1话"),
            samePageChapters: [makeWorkflowChapter(tid: "700", title: "duplicate")],
            cleanBookName: "测试漫画",
            firstPostID: "9001"
        )

        let directory = MangaDirectoryInitialization.directory(from: seed)

        #expect(directory.strategy == .pendingSearch)
        #expect(directory.sourceKey == "测试漫画")
        #expect(directory.chapters.map(\.tid) == ["700"])
    }

    @Test func documentLoadingFailurePublishesFailedPresentation() async throws {
        let loader = RecordingMangaReaderProjectionLoader(output: .failure(.offline))
        let repository = RecordingMangaDirectoryRepository(
            output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"]))
        )
        let store = RecordingMangaDirectoryStore()
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700"),
            projectionLoader: loader,
            directoryRepository: repository,
            directoryStore: store
        )

        let presentation = await workflow.prepare()

        guard case let .failed(error) = presentation.state else {
            Issue.record("Expected failed presentation")
            return
        }
        #expect(error.title == L10n.string("common.load_failed"))
        #expect(error.message == YamiboError.offline.localizedDescription)
        #expect(await repository.seedThreadIDs.isEmpty)
        #expect(await store.savedDirectories.isEmpty)
    }

    @Test func offlineCachedCurrentChapterLoadsFromDirectoryOwnerWithoutLocalDirectory() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let offlineStore = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryWorkflowOfflineCacheDirectory())
        for imageURL in document.imageURLs {
            try await offlineStore.saveOfflineImageData(Data([7]), for: imageURL)
        }
        try await offlineStore.saveMangaOfflineCacheMembership(
            MangaOfflineCacheMembership(
                ownerName: "测试漫画",
                tid: "700",
                chapterTitle: document.chapterTitle,
                imageURLs: document.imageURLs,
                sourcePage: makeWorkflowSourcePage(tid: document.tid)
            )
        )
        let repository = RecordingMangaDirectoryRepository(output: .failure(.offline))
        let store = RecordingMangaDirectoryStore()
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: repository,
            directoryStore: store,
            offlineCacheStore: offlineStore
        )

        let presentation = await workflow.prepare()

        let loaded = try #require(loadedPresentation(in: presentation))
        #expect(loaded.pages.map(\.id) == ["700#0", "700#1"])
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 0))
        #expect(await repository.seedThreadIDs == [document.tid])
        #expect(await store.savedDirectories.isEmpty)
    }

    @Test func workflowPassesDirectoryOwnerWhenLoadingAdjacentChapter() async throws {
        let documents = try ["700", "701"].map { try makeWorkflowDocument(tid: $0, pageCount: 1) }
        let loader = RecordingMangaReaderProjectionLoader(documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) }))
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .searched,
            sourceKey: "local",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: loader,
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        _ = try await workflow.jumpToAdjacentChapter(
            from: MangaReadingPosition(tid: "700", localIndex: 0),
            delta: 1
        )

        let requests = await loader.loadedRequests
        #expect(requests.map(\.threadID) == ["700", "701"])
        #expect(requests.map(\.offlineOwnerName) == ["测试漫画", "测试漫画"])
    }

    @Test func workflowUpdatesDirectoryPreservingCurrentReadingPosition() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .tag,
            sourceKey: "12",
            tids: ["700"]
        )
        let repository = RecordingMangaDirectoryRepository(
            output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"])),
            tagChapters: [
                makeWorkflowChapter(tid: "699", title: "第699话"),
                makeWorkflowChapter(tid: "701", title: "第701话")
            ]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 1, directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: repository,
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let result = try await workflow.updateDirectory()

        guard case let .loaded(loaded) = workflow.presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(result.shouldOfferForcedSearch)
        #expect(loaded.directoryPanel.displayChapters.map(\.tid) == ["699", "700", "701"])
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
        #expect(loaded.currentPage?.id == "700#1")
        #expect(await repository.tagDirectoryRequests == [["12"]])
    }

    @Test func workflowResetsDirectoryReseedingFromNetworkWhilePreservingCurrentReadingPosition() async throws {
        let document = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .searched,
            sourceKey: "旧来源",
            tids: ["700", "999"]
        )
        let repository = RecordingMangaDirectoryRepository(
            output: .seed(makeWorkflowSeed(currentTID: "700", tagIDs: ["12"])),
            tagChapters: [
                makeWorkflowChapter(tid: "699", title: "第699话"),
                makeWorkflowChapter(tid: "701", title: "第701话")
            ]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 1, directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
            directoryRepository: repository,
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let result = try await workflow.resetDirectory()

        guard case let .loaded(loaded) = workflow.presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(result.directory.cleanBookName == "测试漫画")
        #expect(result.directory.strategy == .tag)
        #expect(result.directory.sourceKey == "12")
        #expect(loaded.directoryPanel.displayChapters.map(\.tid) == ["699", "700", "701"])
        #expect(!loaded.directoryPanel.displayChapters.contains(where: { $0.tid == "999" }))
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
        #expect(loaded.currentPage?.id == "700#1")
        #expect(await repository.seedThreadIDs == ["700"])
        #expect(await repository.tagDirectoryRequests == [["12"]])
    }

    @Test func workflowDeletesDirectoryChaptersPreservingCurrentReadingPosition() async throws {
        let documents = try ["699", "700", "701"].map { try makeWorkflowDocument(tid: $0, pageCount: 1) }
        let documentsByTID = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["699", "700", "701"]
        )
        let store = RecordingMangaDirectoryStore(directories: [directory])
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: documentsByTID),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: store
        )

        _ = await workflow.prepare()
        _ = await workflow.prefetchAdjacentChaptersIfNeeded(around: 0)
        let presentation = try await workflow.deleteDirectoryChapters(tids: ["699", "701"])

        let loaded = try #require(loadedPresentation(in: presentation))
        #expect(loaded.directoryPanel.displayChapters.map(\.tid) == ["700"])
        #expect(loaded.pages.map(\.id) == ["700#0"])
        #expect(loaded.currentPage?.id == "700#0")
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 0))
        let saved = try #require(await store.savedDirectories.last)
        #expect(saved.chapters.map(\.tid) == ["700"])
    }

    @Test func workflowJumpsToAlreadyLoadedChapterWithDirectViewportPlacement() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let document701 = try makeWorkflowDocument(tid: "701", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let loader = RecordingMangaReaderProjectionLoader(documents: [
            "700": document700,
            "701": document701
        ])
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: loader,
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        _ = try await workflow.jumpToChapter(directory.chapters[1])
        let presentation = try await workflow.jumpToChapter(directory.chapters[0])

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.pages.map(\.id) == ["700#0", "701#0"])
        #expect(loaded.currentPage?.id == "700#0")
        #expect(loaded.viewportPlacement?.targetPageIndex == 0)
        #expect(loaded.viewportPlacement?.animated == false)
    }

    @Test func workflowJumpsToAdjacentChapterByInsertingDocument() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let document701 = try makeWorkflowDocument(tid: "701", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700,
                "701": document701
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let presentation = try await workflow.jumpToChapter(directory.chapters[1])

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.pages.map(\.id) == ["700#0", "701#0"])
        #expect(loaded.currentPage?.id == "701#0")
        #expect(loaded.viewportPlacement?.targetPageIndex == 1)
    }

    @Test func workflowBoundaryJumpLoadsPreviousAdjacentChapterAtLastPage() async throws {
        let document699 = try makeWorkflowDocument(tid: "699", pageCount: 3)
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 4)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["699", "700"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "699": document699,
                "700": document700
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let presentation = try await workflow.jumpToAdjacentChapter(
            from: MangaReadingPosition(tid: "700", localIndex: 0),
            delta: -1,
            animated: true
        )

        let loaded = try #require(loadedPresentation(in: presentation))
        #expect(loaded.pages.map(\.id) == [
            "699#0", "699#1", "699#2",
            "700#0", "700#1", "700#2", "700#3"
        ])
        #expect(loaded.currentPage?.id == "699#2")
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "699", localIndex: 2))
        #expect(loaded.viewportPlacement?.targetPageIndex == 2)
        #expect(loaded.viewportPlacement?.animated == true)
    }

    @Test func workflowBoundaryJumpLoadsNextAdjacentChapterAtFirstPage() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 4)
        let document701 = try makeWorkflowDocument(tid: "701", pageCount: 3)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 3, directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700,
                "701": document701
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let presentation = try await workflow.jumpToAdjacentChapter(
            from: MangaReadingPosition(tid: "700", localIndex: 3),
            delta: 1,
            animated: true
        )

        let loaded = try #require(loadedPresentation(in: presentation))
        #expect(loaded.pages.map(\.id) == [
            "700#0", "700#1", "700#2", "700#3",
            "701#0", "701#1", "701#2"
        ])
        #expect(loaded.currentPage?.id == "701#0")
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "701", localIndex: 0))
        #expect(loaded.viewportPlacement?.targetPageIndex == 4)
        #expect(loaded.viewportPlacement?.animated == true)
    }

    @Test func workflowBoundaryJumpUsesLoadedAdjacentChapterWithoutReloading() async throws {
        let documents = try ["699", "700", "701"].map { try makeWorkflowDocument(tid: $0, pageCount: 1) }
        let documentsByTID = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["699", "700", "701"]
        )
        let loader = RecordingMangaReaderProjectionLoader(documents: documentsByTID)
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: loader,
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        _ = await workflow.prefetchAdjacentChaptersIfNeeded(around: 0)
        let loadedThreadIDsBeforeJump = await loader.loadedThreadIDs
        let presentation = try await workflow.jumpToAdjacentChapter(
            from: MangaReadingPosition(tid: "700", localIndex: 0),
            delta: -1,
            animated: true
        )

        let loaded = try #require(loadedPresentation(in: presentation))
        #expect(loaded.currentPage?.id == "699#0")
        #expect(await loader.loadedThreadIDs == loadedThreadIDsBeforeJump)
    }

    @Test func workflowBoundaryJumpWithoutAdjacentChapterKeepsPresentationUnchanged() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let before = workflow.presentation

        #expect(!workflow.canJumpToAdjacentChapter(
            from: MangaReadingPosition(tid: "700", localIndex: 0),
            delta: -1
        ))
        await #expect(throws: YamiboError.self) {
            _ = try await workflow.jumpToAdjacentChapter(
                from: MangaReadingPosition(tid: "700", localIndex: 0),
                delta: -1
            )
        }
        #expect(workflow.presentation == before)
    }

    @Test func workflowBoundaryJumpLoadFailureKeepsPresentationUnchanged() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let before = workflow.presentation

        await #expect(throws: YamiboError.self) {
            _ = try await workflow.jumpToAdjacentChapter(
                from: MangaReadingPosition(tid: "700", localIndex: 0),
                delta: 1
            )
        }
        #expect(workflow.presentation == before)
    }

    @Test func workflowBoundaryJumpEmptyAdjacentChapterKeepsPresentationUnchanged() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let document701 = try makeWorkflowDocument(tid: "701", pageCount: 0)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700,
                "701": document701
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let before = workflow.presentation

        await #expect(throws: YamiboError.self) {
            _ = try await workflow.jumpToAdjacentChapter(
                from: MangaReadingPosition(tid: "700", localIndex: 0),
                delta: 1
            )
        }
        #expect(workflow.presentation == before)
    }

    @Test func workflowBoundaryJumpDropsStaleAdjacentLoadWhenSourcePositionChanges() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let document701 = try makeWorkflowDocument(tid: "701", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let loader = BlockingMangaReaderProjectionLoader(
            documents: [
                "700": document700,
                "701": document701
            ],
            delayedThreadIDs: [document701.tid]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 1, directoryName: "测试漫画"),
            projectionLoader: loader,
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let staleJump = Task {
            try await workflow.jumpToAdjacentChapter(
                from: MangaReadingPosition(tid: "700", localIndex: 1),
                delta: 1
            )
        }
        await loader.waitForDelayedLoad()
        let movedPresentation = workflow.moveToLoadedPage(at: 0)
        await loader.resumeDelayedLoads()

        do {
            _ = try await staleJump.value
            Issue.record("Expected stale boundary jump to be cancelled.")
        } catch is CancellationError {
            #expect(workflow.presentation == movedPresentation)
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test func workflowJumpsToDistantChapterByResettingWindow() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let document703 = try makeWorkflowDocument(tid: "703", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701", "702", "703"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700,
                "703": document703
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let presentation = try await workflow.jumpToChapter(directory.chapters[3])

        guard case let .loaded(loaded) = presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.pages.map(\.id) == ["703#0"])
        #expect(loaded.currentPage?.id == "703#0")
        #expect(loaded.viewportPlacement?.targetPageIndex == 0)
    }

    @Test func workflowJumpFailureKeepsCurrentWindowLoaded() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 1)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        await #expect(throws: YamiboError.unreadableBody) {
            _ = try await workflow.jumpToChapter(directory.chapters[1])
        }

        guard case let .loaded(loaded) = workflow.presentation.state else {
            Issue.record("Expected loaded presentation")
            return
        }
        #expect(loaded.pages.map(\.id) == ["700#0"])
        #expect(loaded.currentPage?.id == "700#0")
    }

    @Test func workflowPrefetchNearEndAppendsNextReaderProjection() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 10)
        let document701 = try makeWorkflowDocument(tid: "701", pageCount: 2)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 8, directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700,
                "701": document701
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let presentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: 8)

        guard case let .loaded(loaded)? = presentation?.state else {
            Issue.record("Expected adjacent prefetch to publish a loaded presentation")
            return
        }
        #expect(loaded.pages.map(\.id) == [
            "700#0", "700#1", "700#2", "700#3", "700#4",
            "700#5", "700#6", "700#7", "700#8", "700#9",
            "701#0", "701#1"
        ])
        #expect(loaded.currentPage?.id == "700#8")
        #expect(loaded.currentPageIndex == 8)
        #expect(loaded.viewportPlacement?.targetPageIndex == 8)
        #expect(loaded.viewportPlacement?.animated == false)
    }

    @Test func workflowPrefetchNearBeginningPrependsPreviousReaderProjectionAndStabilizesPlacement() async throws {
        let document699 = try makeWorkflowDocument(tid: "699", pageCount: 3)
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 4)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["699", "700"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 1, directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "699": document699,
                "700": document700
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let presentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: 1)

        guard case let .loaded(loaded)? = presentation?.state else {
            Issue.record("Expected previous prefetch to publish a loaded presentation")
            return
        }
        #expect(loaded.pages.map(\.id) == [
            "699#0", "699#1", "699#2", "700#0", "700#1", "700#2", "700#3"
        ])
        #expect(loaded.readingPosition == MangaReadingPosition(tid: "700", localIndex: 1))
        #expect(loaded.currentPage?.id == "700#1")
        #expect(loaded.currentPageIndex == 4)
        #expect(loaded.viewportPlacement?.targetPageIndex == 4)
        #expect(loaded.viewportPlacement?.animated == false)
    }

    @Test func workflowPrefetchForShortChapterExtendsBothDirectionsWithSinglePlacementRevision() async throws {
        let documents = try ["699", "700", "701"].map { try makeWorkflowDocument(tid: $0, pageCount: 1) }
        let documentsByTID = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["699", "700", "701"]
        )
        let loader = RecordingMangaReaderProjectionLoader(documents: documentsByTID)
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: loader,
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let initialLoaded = try #require(loadedPresentation(in: workflow.presentation))
        let initialRevision = try #require(initialLoaded.viewportPlacement?.revision)
        let presentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: 0)

        let loaded = try #require(loadedPresentation(in: presentation))
        #expect(loaded.pages.map(\.id) == ["699#0", "700#0", "701#0"])
        #expect(loaded.currentPage?.id == "700#0")
        #expect(loaded.viewportPlacement?.targetPageIndex == 1)
        #expect(loaded.viewportPlacement?.revision == initialRevision + 1)
        #expect(await loader.loadedRequests.map(\.offlineOwnerName) == ["测试漫画", "测试漫画", "测试漫画"])
    }

    @Test func workflowAdjacentPrefetchKeepsChapterWindowBoundedToTenDocuments() async throws {
        let tids = (700...712).map(String.init)
        let documents = try tids.map { try makeWorkflowDocument(tid: $0, pageCount: 1) }
        let documentsByTID = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: tids
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: documentsByTID),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        for _ in 0..<12 {
            let loaded = try #require(loadedPresentation(in: workflow.presentation))
            _ = workflow.moveToLoadedPage(at: loaded.pages.count - 1)
            _ = await workflow.prefetchAdjacentChaptersIfNeeded(around: loaded.pages.count - 1)
        }

        let loaded = try #require(loadedPresentation(in: workflow.presentation))
        #expect(Set(loaded.pages.map(\.tid)).count == 10)
        #expect(loaded.pages.map(\.tid).count == 10)
        #expect(loaded.pages.map(\.tid) == Array(tids.suffix(10)))
        #expect(loaded.pages.last?.tid == "712")
    }

    @Test func workflowAdjacentPrefetchFailureKeepsCurrentPresentation() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 10)
        let directory = makeWorkflowDirectory(
            name: "测试漫画",
            strategy: .links,
            sourceKey: "测试漫画",
            tids: ["700", "701"]
        )
        let workflow = MangaReaderWorkflow(
            context: try makeWorkflowContext(tid: "700", initialPage: 8, directoryName: "测试漫画"),
            projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
                "700": document700
            ]),
            directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
            directoryStore: RecordingMangaDirectoryStore(directories: [directory])
        )

        _ = await workflow.prepare()
        let before = workflow.presentation
        let presentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: 8)

        #expect(presentation == nil)
        #expect(workflow.presentation == before)
    }

    @Test func workflowAdjacentPrefetchNoopInsertionsKeepCurrentPresentation() async throws {
        let document700 = try makeWorkflowDocument(tid: "700", pageCount: 10)
        let duplicate700 = try makeWorkflowDocument(tid: "700", pageCount: 2)
        let unknown999 = try makeWorkflowDocument(tid: "999", pageCount: 2)
        let nonAdjacent702 = try makeWorkflowDocument(tid: "702", pageCount: 2)

        try await expectPrefetchNoop(
            initialDocument: document700,
            returnedDocument: duplicate700,
            directoryTIDs: ["700", "701"],
            reason: "duplicate"
        )
        try await expectPrefetchNoop(
            initialDocument: document700,
            returnedDocument: unknown999,
            directoryTIDs: ["700", "701"],
            reason: "unknown"
        )
        try await expectPrefetchNoop(
            initialDocument: document700,
            returnedDocument: nonAdjacent702,
            directoryTIDs: ["700", "701", "702"],
            reason: "not adjacent"
        )
    }
}

@MainActor
private func makeLoadedPresentation(
    context: MangaLaunchContext,
    document: MangaReaderProjection,
    seed: MangaDirectorySeed
) async -> MangaReaderPresentation {
    let workflow = MangaReaderWorkflow(
        context: context,
        projectionLoader: RecordingMangaReaderProjectionLoader(output: .document(document)),
        directoryRepository: RecordingMangaDirectoryRepository(output: .seed(seed)),
        directoryStore: RecordingMangaDirectoryStore()
    )
    return await workflow.prepare()
}

private actor RecordingMangaReaderProjectionLoader: MangaReaderProjectionLoading {
    enum Output: Sendable {
        case document(MangaReaderProjection)
        case failure(YamiboError)
    }

    private let output: Output
    private let documents: [String: MangaReaderProjection]?
    private(set) var loadedThreadIDs: [String] = []
    private(set) var loadedRequests: [MangaReaderProjectionRequest] = []

    init(output: Output) {
        self.output = output
        self.documents = nil
    }

    init(documents: [String: MangaReaderProjection]) {
        self.output = .failure(.unreadableBody)
        self.documents = documents
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        loadedRequests.append(request)
        loadedThreadIDs.append(request.threadID)
        if let documents {
            guard let document = documents[request.threadID] else {
                throw YamiboError.unreadableBody
            }
            return document
        }
        switch output {
        case let .document(document):
            return document
        case let .failure(error):
            throw error
        }
    }
}

private actor BlockingMangaReaderProjectionLoader: MangaReaderProjectionLoading {
    private let documents: [String: MangaReaderProjection]
    private let delayedThreadIDs: Set<String>
    private var delayedLoadContinuations: [CheckedContinuation<Void, Never>] = []
    private var delayedLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadedThreadIDs: [String] = []

    init(
        documents: [String: MangaReaderProjection],
        delayedThreadIDs: Set<String>
    ) {
        self.documents = documents
        self.delayedThreadIDs = delayedThreadIDs
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        loadedThreadIDs.append(request.threadID)
        if delayedThreadIDs.contains(request.threadID) {
            delayedLoadWaiters.forEach { $0.resume() }
            delayedLoadWaiters.removeAll()
            await withCheckedContinuation { continuation in
                delayedLoadContinuations.append(continuation)
            }
        }
        guard let document = documents[request.threadID] else {
            throw YamiboError.unreadableBody
        }
        return document
    }

    func waitForDelayedLoad() async {
        guard delayedLoadContinuations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            delayedLoadWaiters.append(continuation)
        }
    }

    func resumeDelayedLoads() {
        let continuations = delayedLoadContinuations
        delayedLoadContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor RecordingMangaDirectoryRepository: MangaDirectoryRepository {
    enum Output: Sendable {
        case seed(MangaDirectorySeed)
        case failure(YamiboError)
    }

    private let output: Output
    private let tagChapters: [MangaChapter]
    private let searchChapters: [MangaChapter]
    private(set) var seedThreadIDs: [String] = []
    private(set) var tagDirectoryRequests: [[String]] = []
    private(set) var searchRequests: [(keyword: String, forumID: String)] = []

    init(
        output: Output,
        tagChapters: [MangaChapter] = [],
        searchChapters: [MangaChapter] = []
    ) {
        self.output = output
        self.tagChapters = tagChapters
        self.searchChapters = searchChapters
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        seedThreadIDs.append(threadID)
        switch output {
        case let .seed(seed):
            return seed
        case let .failure(error):
            throw error
        }
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        tagDirectoryRequests.append(tagIDs)
        return tagChapters
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        searchRequests.append((keyword, forumID))
        return searchChapters
    }
}

private actor RecordingMangaDirectoryStore: MangaDirectoryPersisting {
    private var directories: [String: MangaDirectory]
    private(set) var requestedNames: [String] = []
    private(set) var requestedTIDs: [String] = []
    private(set) var savedDirectories: [MangaDirectory] = []
    private(set) var deletedNames: [String] = []

    init(directories: [MangaDirectory] = []) {
        self.directories = Dictionary(
            uniqueKeysWithValues: directories.map { (Self.normalizedName($0.cleanBookName), $0) }
        )
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        let normalized = Self.normalizedName(name)
        requestedNames.append(normalized)
        return directories[normalized]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        let normalized = Self.normalizedName(tid)
        requestedTIDs.append(normalized)
        guard !normalized.isEmpty else { return nil }
        return directories.values.first { directory in
            directory.chapters.contains(where: { Self.normalizedName($0.tid) == normalized })
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        savedDirectories.append(directory)
        directories[Self.normalizedName(directory.cleanBookName)] = directory
    }

    func deleteDirectory(named name: String) async throws {
        let normalized = Self.normalizedName(name)
        deletedNames.append(normalized)
        directories.removeValue(forKey: normalized)
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func makeWorkflowContext(
    tid: String,
    initialPage: Int = 0,
    directoryName: String? = nil,
    offlineCacheFavoriteID: String? = nil,
    isSmartModeEnabled: Bool = true
) throws -> MangaLaunchContext {
    MangaLaunchContext(
        originalThreadID: tid,
        chapterTID: tid,
        displayTitle: "测试漫画",
        source: .forum,
        initialPage: initialPage,
        directoryName: directoryName,
        offlineCacheFavoriteID: offlineCacheFavoriteID,
        isSmartModeEnabled: isSmartModeEnabled
    )
}

private func makeWorkflowSeed(
    currentTID: String,
    tagIDs: [String] = []
) -> MangaDirectorySeed {
    MangaDirectorySeed(
        currentChapter: makeWorkflowChapter(tid: currentTID, title: "第1话"),
        tagIDs: tagIDs,
        cleanBookName: "测试漫画"
    )
}

private func makeWorkflowDirectory(
    name: String,
    strategy: MangaDirectoryStrategy,
    sourceKey: String,
    tids: [String]
) -> MangaDirectory {
    MangaDirectory(
        cleanBookName: name,
        strategy: strategy,
        sourceKey: sourceKey,
        chapters: tids.map { makeWorkflowChapter(tid: $0, title: "第\($0)话") }
    )
}

private func makeWorkflowChapter(tid: String, title: String) -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: title,
        chapterNumber: Double(tid) ?? 0
    )
}

private func makeWorkflowDocument(tid: String, pageCount: Int) throws -> MangaReaderProjection {
    let imageURLs = try (0..<pageCount).map { index in
        try #require(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
    }
    return MangaReaderProjection(
        tid: tid,
        ownerPostID: "post-\(tid)",
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs
    )
}

private func makeWorkflowSourcePage(tid: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "post-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: "",
                contentText: ""
            )
        ]
    )
}

private func makeWorkflowURL(tid: String) -> URL {
    URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=\(tid)&mobile=2")!
}

private func makeTemporaryWorkflowOfflineCacheDirectory() throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func loadedPresentation(in presentation: MangaReaderPresentation?) -> MangaReaderLoadedPresentation? {
    guard case let .loaded(loaded)? = presentation?.state else { return nil }
    return loaded
}

@MainActor
private func expectPrefetchNoop(
    initialDocument: MangaReaderProjection,
    returnedDocument: MangaReaderProjection,
    directoryTIDs: [String],
    reason: String
) async throws {
    let directory = makeWorkflowDirectory(
        name: "测试漫画",
        strategy: .links,
        sourceKey: "测试漫画",
        tids: directoryTIDs
    )
    let workflow = MangaReaderWorkflow(
        context: try makeWorkflowContext(tid: initialDocument.tid, initialPage: 8, directoryName: "测试漫画"),
        projectionLoader: RecordingMangaReaderProjectionLoader(documents: [
            initialDocument.tid: initialDocument,
            "701": returnedDocument
        ]),
        directoryRepository: RecordingMangaDirectoryRepository(output: .failure(.offline)),
        directoryStore: RecordingMangaDirectoryStore(directories: [directory])
    )

    _ = await workflow.prepare()
    let before = workflow.presentation
    let presentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: 8)

    if presentation != nil || workflow.presentation != before {
        Issue.record("Expected \(reason) adjacent prefetch insertion to leave presentation unchanged")
    }
}
