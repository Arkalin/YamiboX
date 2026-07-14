import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("ReaderSharedTests: Offline Cache Queue Executor")
struct ReaderSharedTestsOfflineCacheQueueExecutor {
    @Test func continueProcessesOneChapterAtATimeWithThreeImageTransferLimit() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let firstChapterImages = try makeImageURLs(tid: "100", count: 4)
        let secondChapterImages = try makeImageURLs(tid: "200", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "100", targetImageURLs: firstChapterImages)
        )
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "200", targetImageURLs: secondChapterImages)
        )
        let acquirer = RecordingOfflineImageAcquirer(delayNanoseconds: 20_000_000)
        await acquirer.setData(for: firstChapterImages + secondChapterImages)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "100", imageURLs: firstChapterImages),
                try makeDocument(tid: "200", imageURLs: secondChapterImages)
            ]),
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        let requestedURLs = await acquirer.requestedURLs
        let firstSecondChapterIndex = try #require(requestedURLs.firstIndex(of: secondChapterImages[0]))
        let lastFirstChapterIndex = try #require(firstChapterImages.compactMap { requestedURLs.firstIndex(of: $0) }.max())
        #expect(lastFirstChapterIndex < firstSecondChapterIndex)
        #expect(await acquirer.maxActiveCount <= 3)
        #expect(await store.mangaQueueWork(ownerName: "favorite-a", tid: "100") == nil)
        #expect(await store.mangaQueueWork(ownerName: "favorite-a", tid: "200") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .cached)
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "200") == .cached)
    }

    @Test func continueLoadsReaderProjectionBeforeImageCountProgressUsingTid() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "300", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            MangaOfflineCacheWorkRequest(
                ownerName: "favorite-a",
                tid: "300",
                chapterTitle: "第300话",
                targetImageURLs: []
            )
        )
        let projectionLoader = RecordingReaderProjectionLoader()
        await projectionLoader.setDocument(
            try makeDocument(tid: "300", imageURLs: imageURLs),
            forAnyRequest: true
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: projectionLoader,
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await projectionLoader.requestedThreadIDs == ["300"])
        let completedWork = await store.mangaQueueWork(ownerName: "favorite-a", tid: "300")
        #expect(completedWork == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "300") == .cached)
        #expect(await store.mangaOfflineCacheMembership(ownerName: "favorite-a", tid: "300")?.sourcePage.thread == ThreadIdentity(tid: "300"))
    }

    @Test func continueLoadsSnapshotEvenWhenWorkAlreadyHasTargetImages() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let staleImages = try makeImageURLs(tid: "310", count: 1)
        let projectionImages = try makeImageURLs(tid: "311", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "310", targetImageURLs: staleImages)
        )
        let projectionLoader = RecordingReaderProjectionLoader(documents: [
            try makeDocument(tid: "310", imageURLs: projectionImages)
        ])
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: projectionImages)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: projectionLoader,
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await projectionLoader.requestedThreadIDs == ["310"])
        #expect(await acquirer.requestedURLs == projectionImages)
        let membership = try #require(await store.mangaOfflineCacheMembership(ownerName: "favorite-a", tid: "310"))
        #expect(membership.imageURLs == projectionImages)
        #expect(membership.sourcePage.thread == ThreadIdentity(tid: "310"))
    }

    @Test func snapshotLoadFailureFailsWorkWithoutCreatingMembership() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "320", count: 1)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "320", targetImageURLs: imageURLs)
        )
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            imageAcquirer: RecordingOfflineImageAcquirer()
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        let failedWork = try #require(await store.mangaQueueWork(ownerName: "favorite-a", tid: "320"))
        #expect(failedWork.state == .failed)
        #expect(await store.mangaOfflineCacheMembership(ownerName: "favorite-a", tid: "320") == nil)
    }

    @Test func emptyProjectionImageListFailsWorkWithoutCreatingMembership() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "330", targetImageURLs: [])
        )
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "330", imageURLs: [])
            ]),
            imageAcquirer: RecordingOfflineImageAcquirer()
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        let failedWork = try #require(await store.mangaQueueWork(ownerName: "favorite-a", tid: "330"))
        #expect(failedWork.state == .failed)
        #expect(await store.mangaOfflineCacheMembership(ownerName: "favorite-a", tid: "330") == nil)
    }

    @Test func cacheCompletionDoesNotUpdateReadingProgressResumeRouteOrRecentReading() async throws {
        let suiteName = "manga-offline-cache-no-progress-side-effects-\(UUID().uuidString)"
        try #require(UserDefaults(suiteName: suiteName)).removePersistentDomain(forName: suiteName)
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try #require(UserDefaults(suiteName: suiteName)),
            key: "local-favorites"
        )
        let resumeRouteStore = ReaderResumeRouteStore(defaults: try #require(UserDefaults(suiteName: suiteName)), key: "resume-route")
        var favoriteLibrary = FavoriteLibraryDocument()
        let favorite = try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "350"),
            title: "阅读进度漫画",
            locations: [.category(favoriteLibrary.defaultCategory.id)]
        )
        favoriteLibrary.upsertItem(favorite)
        let resumeRoute = ReaderResumeRoute.manga(MangaLaunchContext(
            originalThreadID: "350",
            chapterTID: "350",
            displayTitle: "阅读进度漫画",
            source: .resume,
            chapterView: 2,
            initialPage: 5
        ))
        let imageURLs = try makeImageURLs(tid: "350", count: 2)
        try await localFavoriteLibraryStore.save(favoriteLibrary)
        try await resumeRouteStore.save(resumeRoute)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: favorite.id, tid: "350", targetImageURLs: imageURLs)
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "350", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.mangaOfflineCacheState(ownerName: favorite.id, tid: "350") == .cached)
        #expect(try await localFavoriteLibraryStore.load() == favoriteLibrary)
        #expect(await resumeRouteStore.load() == .manga(MangaLaunchContext(
            originalThreadID: "350",
            chapterTID: "350",
            displayTitle: "阅读进度漫画",
            source: .resume,
            chapterView: 2,
            initialPage: 5
        )))
    }

    @Test func pauseCancelsInFlightTransfersAndPreservesCompletedProgress() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "400", count: 4)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "400", targetImageURLs: imageURLs)
        )
        let acquirer = FirstImageOnlyImmediateAcquirer(firstImageURL: imageURLs[0])
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "400", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        try await waitUntil {
            await store.mangaQueueWork(ownerName: "favorite-a", tid: "400")?.completedImageURLs == [imageURLs[0]]
        }
        try await executor.pauseQueue()
        await executor.waitForIdle()

        let work = try #require(await store.mangaQueueWork(ownerName: "favorite-a", tid: "400"))
        #expect(work.completedImageURLs == [imageURLs[0]])
        #expect(work.progress == OfflineCacheProgress(completedUnitCount: 1, targetUnitCount: 4))
        #expect(work.currentBytesPerSecond == 0)
        #expect(await store.offlineCacheQueueRunState() == .paused)
        #expect(await store.offlineImageData(for: imageURLs[0]) == Data([1]))
        #expect(await store.offlineImageData(for: imageURLs[1]) == nil)
    }

    @Test func failedWorkRemainsQueuedAndContinueRetriesFromRetainedProgress() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "500", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "500", targetImageURLs: imageURLs)
        )
        let acquirer = RetryOfflineImageAcquirer(failingImageURL: imageURLs[1])
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "500", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer,
            maxConcurrentImageTransfers: 1
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        let failedWork = try #require(await store.mangaQueueWork(ownerName: "favorite-a", tid: "500"))
        #expect(failedWork.state == .failed)
        #expect(failedWork.completedImageURLs == [imageURLs[0]])
        #expect(await store.offlineImageData(for: imageURLs[0]) == Data([1]))

        await acquirer.allowRetry()
        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.mangaQueueWork(ownerName: "favorite-a", tid: "500") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "500") == .cached)
        #expect(await acquirer.requestedURLs == [imageURLs[1]])
    }

    @Test func emptyImageDataFailsWorkWithoutAdvancingProgress() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "550", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "550", targetImageURLs: imageURLs)
        )
        let acquirer = EmptyImageThenFailingAcquirer(emptyImageURL: imageURLs[0])
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "550", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer,
            maxConcurrentImageTransfers: 1
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        let failedWork = try #require(await store.mangaQueueWork(ownerName: "favorite-a", tid: "550"))
        #expect(failedWork.state == .failed)
        #expect(failedWork.completedImageURLs.isEmpty)
        #expect(failedWork.progress == OfflineCacheProgress(completedUnitCount: 0, targetUnitCount: 2))
        #expect(await store.offlineImageData(for: imageURLs[0]) == nil)
        #expect(await acquirer.requestedURLs == [imageURLs[0]])
    }

    @Test func continueReconcilesPersistedProgressAgainstOfflineImageStorage() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "600", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "600", targetImageURLs: imageURLs)
        )
        try await store.saveOfflineImageData(Data([1]), for: imageURLs[0])
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "favorite-a",
            tid: "600",
            targetImageURLs: imageURLs,
            completedImageURLs: imageURLs,
            currentBytesPerSecond: nil
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: [imageURLs[1]])
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "600", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await acquirer.requestedURLs == [imageURLs[1]])
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "600") == .cached)
    }

    @Test func queueWritesNetworkAcquiredBytesToOfflineStorage() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "700", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "700", targetImageURLs: imageURLs)
        )
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let dataByURL = [
            imageURLs[0]: Data([7]),
            imageURLs[1]: Data([8])
        ]
        harness.setHandler { request in
            guard let url = request.url, let data = dataByURL[url] else {
                throw YamiboError.invalidResponse(statusCode: 404)
            }
            return MangaReaderDataTestResponse(data: data)
        }
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "700", imageURLs: imageURLs)
            ]),
            imageAcquirer: OfflineCacheImageAcquirer(
                imagePipeline: harness.makeImagePipeline()
            )
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.offlineImageData(for: imageURLs[0]) == Data([7]))
        #expect(await store.offlineImageData(for: imageURLs[1]) == Data([8]))
        #expect(Set(harness.requests.compactMap(\.url)) == Set(imageURLs))
    }

    @Test func imageAcquirerUsesBackgroundTransportInsteadOfNetworkLoader() async throws {
        let imageURL = try #require(URL(string: "https://img.example.com/710-1.jpg"))
        let transport = RecordingImageTransport(dataByURL: [imageURL: Data([8])])
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            throw YamiboError.invalidResponse(statusCode: 500)
        }
        let acquirer = OfflineCacheImageAcquirer(
            imagePipeline: harness.makeImagePipeline(),
            backgroundTransport: transport
        )
        let refererURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?tid=710"))

        let source = YamiboImageSource(url: imageURL, refererPageURL: refererURL)
        let acquisition = try await acquirer.acquireImageData(for: source)

        #expect(acquisition == OfflineCacheImageAcquisition(data: Data([8]), source: .network))
        #expect(await transport.requests == [source])
        #expect(harness.requests.isEmpty)
    }

    @Test func observerReceivesSubmissionProgressAndSuccessfulFinish() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "720", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "720", targetImageURLs: imageURLs)
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let observer = RecordingQueueRunObserver()
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "720", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer,
            runObserver: observer,
            maxConcurrentImageTransfers: 1
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await observer.submissionCount == 1)
        #expect(await observer.progressUpdates == [
            OfflineCacheProgress(completedUnitCount: 0, targetUnitCount: 2),
            OfflineCacheProgress(completedUnitCount: 1, targetUnitCount: 2),
            OfflineCacheProgress(completedUnitCount: 2, targetUnitCount: 2)
        ])
        #expect(await observer.finishResults == [true])
    }

    @Test func observerIsNotResubmittedForSystemContinuedProcessingLaunch() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "730", count: 1)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "730", targetImageURLs: imageURLs)
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let observer = RecordingQueueRunObserver()
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "730", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer,
            runObserver: observer
        )

        try await executor.continueQueue(submitsUserInitiatedRun: false)
        await executor.waitForIdle()

        #expect(await observer.submissionCount == 0)
        #expect(await observer.finishResults == [true])
    }

    @Test func continueWhileAlreadyRunningDoesNotSubmitAnotherContinuedProcessingRun() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "735", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "favorite-a", tid: "735", targetImageURLs: imageURLs)
        )
        let acquirer = FirstImageOnlyImmediateAcquirer(firstImageURL: imageURLs[0])
        let observer = RecordingQueueRunObserver()
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "735", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer,
            runObserver: observer
        )

        try await executor.continueQueue()
        try await waitUntil {
            await store.mangaQueueWork(ownerName: "favorite-a", tid: "735")?.completedImageURLs == [imageURLs[0]]
        }
        try await executor.continueQueue()
        try await executor.pauseQueue()
        await executor.waitForIdle()

        #expect(await observer.submissionCount == 1)
    }

    @Test func urlSessionDownloadTransportReturnsDownloadedDataAndReferer() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let imageURL = try #require(URL(string: "https://img.example.com/740-1.jpg"))
        let refererURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?tid=740"))
        harness.setHandler { request in
            #expect(request.url == imageURL)
            #expect(request.value(forHTTPHeaderField: "Referer") == refererURL.absoluteString)
            return MangaReaderDataTestResponse(data: Data([7, 4, 0]))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MangaReaderDataTestURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Manga-Test-ID": harness.testID]
        let transport = OfflineCacheBackgroundDownloadTransport(configuration: configuration)

        let data = try await transport.downloadImageData(for: YamiboImageSource(url: imageURL, refererPageURL: refererURL))

        #expect(data == Data([7, 4, 0]))
        #expect(harness.requests.count == 1)
    }

    @Test func chapterCancellationRemovesPartialOfflineBytesForCanceledWork() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "800", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "作品A", tid: "800", targetImageURLs: imageURLs)
        )
        try await store.saveOfflineImageData(Data([1]), for: imageURLs[0])
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "800",
            targetImageURLs: imageURLs,
            completedImageURLs: [imageURLs[0]],
            currentBytesPerSecond: nil
        )
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            imageAcquirer: RecordingOfflineImageAcquirer()
        )

        try await executor.cancelChapter(ownerName: "作品A", tid: "800")

        #expect(await store.mangaQueueWork(ownerName: "作品A", tid: "800") == nil)
        #expect(await store.offlineImageData(for: imageURLs[0]) == nil)
    }

    @Test func ownerGroupCancellationRemovesPartialOfflineBytesForCanceledWorkOnly() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let canceledImages = try makeImageURLs(tid: "900", count: 1)
        let retainedImages = try makeImageURLs(tid: "901", count: 1)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "作品A", tid: "900", targetImageURLs: canceledImages)
        )
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "作品B", tid: "901", targetImageURLs: retainedImages)
        )
        try await store.saveOfflineImageData(Data([9]), for: canceledImages[0])
        try await store.saveOfflineImageData(Data([1]), for: retainedImages[0])
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "900",
            targetImageURLs: canceledImages,
            completedImageURLs: canceledImages,
            currentBytesPerSecond: nil
        )
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "作品B",
            tid: "901",
            targetImageURLs: retainedImages,
            completedImageURLs: retainedImages,
            currentBytesPerSecond: nil
        )
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            imageAcquirer: RecordingOfflineImageAcquirer()
        )

        try await executor.cancelOwnerGroup(ownerName: "作品A")

        #expect(await store.mangaQueueWork(ownerName: "作品A", tid: "900") == nil)
        #expect(await store.mangaQueueWork(ownerName: "作品B", tid: "901") != nil)
        #expect(await store.offlineImageData(for: canceledImages[0]) == nil)
        #expect(await store.offlineImageData(for: retainedImages[0]) == Data([1]))
    }

    @Test func continueProcessesNovelWorkWithoutImagesWhenRetentionFlagDisabled() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "1100", count: 2)
        let request = try makeNovelExecutorWorkRequest(tid: "1100", view: 1, retainsInlineImages: false)
        _ = try await store.enqueueNovelOfflineCacheWork(request)
        let sourceLoader = RecordingNovelOfflineSourcePageLoader()
        await sourceLoader.setPreparedPage(
            try makeNovelExecutorPreparedSourcePage(tid: "1100", view: 1, imageURLs: imageURLs),
            for: request
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            novelSourcePageLoader: sourceLoader,
            imageAcquirer: acquirer
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.offlineCacheQueueWorks().isEmpty)
        #expect(await acquirer.requestedURLs.isEmpty)
        #expect(await store.offlineImageData(for: imageURLs[0]) == nil)
        let entry = await store.novelOfflineCacheEntry(id: OfflineCacheEntryID(
            readerKind: .novel,
            ownerKey: request.groupKey,
            entryKey: request.entryKey
        ))
        #expect(entry?.imageURLs.isEmpty == true)
        #expect(entry?.document.segments.contains { segment in
            guard case let .text(text, _) = segment else { return false }
            return text.contains("正文1")
        } == true)
    }

    @Test func continueProcessesNovelInlineImagesWhenRetentionFlagEnabled() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "1110", count: 2)
        let request = try makeNovelExecutorWorkRequest(tid: "1110", view: 1, retainsInlineImages: true)
        _ = try await store.enqueueNovelOfflineCacheWork(request)
        let sourceLoader = RecordingNovelOfflineSourcePageLoader()
        await sourceLoader.setPreparedPage(
            try makeNovelExecutorPreparedSourcePage(tid: "1110", view: 1, imageURLs: imageURLs),
            for: request
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            novelSourcePageLoader: sourceLoader,
            imageAcquirer: acquirer,
            maxConcurrentImageTransfers: 1
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.offlineCacheQueueWorks().isEmpty)
        #expect(await acquirer.requestedURLs == imageURLs)
        #expect(await store.offlineImageData(for: imageURLs[0]) == Data([1]))
        #expect(await store.offlineImageData(for: imageURLs[1]) == Data([2]))
        let entry = await store.novelOfflineCacheEntry(id: OfflineCacheEntryID(
            readerKind: .novel,
            ownerKey: request.groupKey,
            entryKey: request.entryKey
        ))
        #expect(entry?.imageURLs == imageURLs)
    }

    @Test func failedNovelImageAcquisitionPreservesRefreshedSourcePageAndFailedWork() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "1120", count: 2)
        let request = try makeNovelExecutorWorkRequest(tid: "1120", view: 2, retainsInlineImages: true)
        _ = try await store.enqueueNovelOfflineCacheWork(request)
        let sourceLoader = RecordingNovelOfflineSourcePageLoader()
        let preparedPage = try makeNovelExecutorPreparedSourcePage(tid: "1120", view: 2, imageURLs: imageURLs)
        await sourceLoader.setPreparedPage(preparedPage, for: request)
        let acquirer = RetryOfflineImageAcquirer(failingImageURL: imageURLs[1])
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            novelSourcePageLoader: sourceLoader,
            imageAcquirer: acquirer,
            maxConcurrentImageTransfers: 1
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        let failedWork = try #require(await store.offlineCacheQueueWorks().first)
        #expect(failedWork.state == .failed)
        #expect(failedWork.progress == OfflineCacheProgress(completedUnitCount: 1, targetUnitCount: 2))
        #expect(await store.offlineImageData(for: imageURLs[0]) == Data([1]))
        #expect(await store.offlineImageData(for: imageURLs[1]) == nil)
        let sourceSnapshot = await store.novelOfflineSourcePageSnapshot(
            threadID: request.threadID,
            view: request.view,
            authorID: request.authorID
        )
        #expect(sourceSnapshot?.sourcePage == preparedPage.sourcePage)
        let entry = await store.novelOfflineCacheEntry(id: OfflineCacheEntryID(
            readerKind: .novel,
            ownerKey: request.groupKey,
            entryKey: request.entryKey
        ))
        #expect(entry?.imageURLs == imageURLs)
    }

    @Test func continueProcessesNovelWorkAfterOwnerTitleChanges() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let originalRequest = try makeNovelExecutorWorkRequest(
            tid: "1130",
            view: 1,
            retainsInlineImages: false,
            ownerTitle: "旧标题1130"
        )
        let renamedRequest = try makeNovelExecutorWorkRequest(
            tid: "1130",
            view: 1,
            retainsInlineImages: false,
            ownerTitle: "新标题1130"
        )
        _ = try await store.enqueueNovelOfflineCacheWork(originalRequest)
        _ = try await store.enqueueNovelOfflineCacheWork(renamedRequest)
        let sourceLoader = RecordingNovelOfflineSourcePageLoader()
        await sourceLoader.setPreparedPage(
            try makeNovelExecutorPreparedSourcePage(tid: "1130", view: 1, imageURLs: []),
            for: renamedRequest
        )
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(),
            novelSourcePageLoader: sourceLoader,
            imageAcquirer: RecordingOfflineImageAcquirer()
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.offlineCacheQueueWorks().isEmpty)
        #expect(await sourceLoader.requests.map(\.ownerTitle) == ["新标题1130"])
        let entry = await store.novelOfflineCacheEntry(id: OfflineCacheEntryID(
            readerKind: .novel,
            ownerKey: renamedRequest.groupKey,
            entryKey: renamedRequest.entryKey
        ))
        #expect(entry?.ownerTitle == "新标题1130")
    }

    @Test func workProcessorDownloadsOnlyMissingImagesAndReportsOrderedProgress() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "1200", count: 3)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "processor", tid: "1200", targetImageURLs: [])
        )
        try await store.saveOfflineImageData(Data([9]), for: imageURLs[0])
        let work = try #require(await store.nextOfflineCacheProcessingWork())
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: Array(imageURLs.dropFirst()))
        let observer = RecordingQueueRunObserver()
        let strategy = RecordingOfflineCacheWorkStrategy(targetImageURLs: imageURLs)
        let processor = makeRecordingWorkProcessor(
            store: store,
            imageAcquirer: acquirer,
            runObserver: observer,
            strategy: strategy,
            maxConcurrentImageTransfers: 1
        )

        try await processor.process(work)

        #expect(await acquirer.requestedURLs == Array(imageURLs.dropFirst()))
        #expect(await store.offlineImageData(for: imageURLs[0]) == Data([9]))
        #expect(await store.offlineImageData(for: imageURLs[1]) == Data([1]))
        #expect(await store.offlineImageData(for: imageURLs[2]) == Data([2]))
        #expect(await observer.progressUpdates == [
            OfflineCacheProgress(completedUnitCount: 1, targetUnitCount: 3),
            OfflineCacheProgress(completedUnitCount: 2, targetUnitCount: 3),
            OfflineCacheProgress(completedUnitCount: 3, targetUnitCount: 3)
        ])
        #expect(await strategy.persistCount == 1)
        #expect(await strategy.finishCount == 1)
    }

    @Test func workProcessorFinishesEmptyTargetWithoutPreparingTransferProgress() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let staleImageURLs = try makeImageURLs(tid: "1210", count: 1)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "processor", tid: "1210", targetImageURLs: staleImageURLs)
        )
        let work = try #require(await store.nextOfflineCacheProcessingWork())
        let acquirer = RecordingOfflineImageAcquirer()
        let observer = RecordingQueueRunObserver()
        let strategy = RecordingOfflineCacheWorkStrategy(targetImageURLs: [])
        let processor = makeRecordingWorkProcessor(
            store: store,
            imageAcquirer: acquirer,
            runObserver: observer,
            strategy: strategy
        )

        try await processor.process(work)

        let retainedWork = try #require(await store.offlineCacheProcessingWork(id: work.id))
        #expect(retainedWork.state == .queued)
        #expect(retainedWork.targetImageURLs == staleImageURLs)
        #expect(await acquirer.requestedURLs.isEmpty)
        #expect(await observer.progressUpdates.isEmpty)
        #expect(await strategy.persistCount == 1)
        #expect(await strategy.finishCount == 1)
    }

    @Test func workProcessorRejectsEmptyImageDataWithoutAdvancingProgress() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "1220", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "processor", tid: "1220", targetImageURLs: [])
        )
        let work = try #require(await store.nextOfflineCacheProcessingWork())
        let acquirer = EmptyImageThenFailingAcquirer(emptyImageURL: imageURLs[0])
        let strategy = RecordingOfflineCacheWorkStrategy(targetImageURLs: imageURLs)
        let processor = makeRecordingWorkProcessor(
            store: store,
            imageAcquirer: acquirer,
            strategy: strategy,
            maxConcurrentImageTransfers: 1
        )

        do {
            try await processor.process(work)
            Issue.record("Expected empty image data to fail the processor")
        } catch let error as YamiboError {
            #expect(error == .invalidResponse(statusCode: nil))
        }

        let retainedWork = try #require(await store.offlineCacheProcessingWork(id: work.id))
        #expect(retainedWork.completedImageURLs.isEmpty)
        #expect(await store.offlineImageData(for: imageURLs[0]) == nil)
        #expect(await strategy.finishCount == 0)
    }

    @Test func workProcessorCancelsWhenWorkIsRemovedDuringTransfer() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryExecutorDirectory())
        let imageURLs = try makeImageURLs(tid: "1230", count: 1)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeExecutorWorkRequest(ownerName: "processor", tid: "1230", targetImageURLs: [])
        )
        let work = try #require(await store.nextOfflineCacheProcessingWork())
        let acquirer = CancelingOfflineImageAcquirer(store: store, workID: work.id)
        let strategy = RecordingOfflineCacheWorkStrategy(targetImageURLs: imageURLs)
        let processor = makeRecordingWorkProcessor(
            store: store,
            imageAcquirer: acquirer,
            strategy: strategy,
            maxConcurrentImageTransfers: 1
        )

        do {
            try await processor.process(work)
            Issue.record("Expected removed work to cancel the processor")
        } catch is CancellationError {
            #expect(true)
        }

        #expect(await store.offlineCacheProcessingWork(id: work.id) == nil)
        #expect(await store.offlineImageData(for: imageURLs[0]) == nil)
        #expect(await strategy.finishCount == 0)
    }
}

private func makeRecordingWorkProcessor(
    store: any TestOfflineCacheStoring,
    imageAcquirer: any OfflineCacheImageAcquiring,
    runObserver: (any OfflineCacheQueueRunObserving)? = nil,
    strategy: RecordingOfflineCacheWorkStrategy,
    maxConcurrentImageTransfers: Int = 3
) -> OfflineCacheWorkProcessor<RecordingOfflineCacheWorkStrategy> {
    OfflineCacheWorkProcessor(
        store: store,
        imageAcquirer: imageAcquirer,
        runObserver: runObserver,
        maxConcurrentImageTransfers: maxConcurrentImageTransfers,
        strategy: strategy
    )
}

private struct RecordingOfflineCachePayload: Sendable {}

private actor RecordingOfflineCacheWorkStrategy: OfflineCacheWorkProcessingStrategy {
    private(set) var prepareCount = 0
    private(set) var persistCount = 0
    private(set) var finishCount = 0
    private let targetImageURLs: [URL]
    private let refererURL: URL

    init(targetImageURLs: [URL]) {
        self.targetImageURLs = targetImageURLs
        self.refererURL = YamiboRoute.threadByID(tid: "processor", page: 1, authorID: nil, reverse: false).url
    }

    func prepare(_ work: OfflineCacheProcessingWork) async throws -> OfflineCachePreparedWork<RecordingOfflineCachePayload> {
        prepareCount += 1
        return OfflineCachePreparedWork(
            workID: work.id,
            targetImageURLs: targetImageURLs,
            refererURL: refererURL,
            payload: RecordingOfflineCachePayload()
        )
    }

    func persistPreparedSource(_ preparedWork: OfflineCachePreparedWork<RecordingOfflineCachePayload>) async throws {
        persistCount += 1
    }

    func finish(_ preparedWork: OfflineCachePreparedWork<RecordingOfflineCachePayload>) async throws {
        finishCount += 1
    }
}

private actor RecordingReaderProjectionLoader: MangaReaderProjectionSnapshotLoading {
    private(set) var requestedThreadIDs: [String] = []
    private var documentByTID: [String: MangaReaderProjection] = [:]
    private var anyDocument: MangaReaderProjection?

    init(documents: [MangaReaderProjection] = []) {
        self.documentByTID = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
    }

    func setDocument(_ document: MangaReaderProjection, forAnyRequest: Bool = false) {
        if forAnyRequest {
            anyDocument = document
        } else {
            documentByTID[document.tid] = document
        }
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        requestedThreadIDs.append(request.threadID)
        if let document = documentByTID[request.threadID] ?? anyDocument {
            return document
        }
        throw YamiboError.parsingFailed(context: "Missing test Manga Chapter Document")
    }

    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjectionSnapshot {
        let projection = try await loadReaderProjection(request)
        return MangaReaderProjectionSnapshot(
            projection: projection,
            sourcePage: makeSourcePage(projection: projection)
        )
    }

    private func makeSourcePage(projection: MangaReaderProjection) -> ForumThreadPage {
        ForumThreadPage(
            thread: ThreadIdentity(tid: projection.tid),
            title: projection.chapterTitle,
            posts: [
                ForumThreadPost(
                    postID: projection.ownerPostID,
                    author: BlogReaderUser(uid: projection.ownerAuthorID, name: projection.ownerAuthorName ?? "作者"),
                    contentHTML: "",
                    contentText: "",
                    images: projection.imageURLs.map { ForumThreadPostImage(url: $0.absoluteString) }
                )
            ]
        )
    }
}

private actor RecordingOfflineImageAcquirer: OfflineCacheImageAcquiring {
    private(set) var requestedURLs: [URL] = []
    private(set) var maxActiveCount = 0
    private let delayNanoseconds: UInt64
    private var activeCount = 0
    private var dataByURL: [URL: Data] = [:]

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func setData(for imageURLs: [URL]) {
        for (index, imageURL) in imageURLs.enumerated() {
            dataByURL[imageURL] = Data([UInt8((index % 200) + 1)])
        }
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        requestedURLs.append(source.url)
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
        defer { activeCount -= 1 }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard let data = dataByURL[source.url] else {
            throw YamiboError.invalidResponse(statusCode: 404)
        }
        return OfflineCacheImageAcquisition(data: data, source: .network)
    }
}

private actor FirstImageOnlyImmediateAcquirer: OfflineCacheImageAcquiring {
    private let firstImageURL: URL

    init(firstImageURL: URL) {
        self.firstImageURL = firstImageURL
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        if source.url == firstImageURL {
            return OfflineCacheImageAcquisition(data: Data([1]), source: .network)
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return OfflineCacheImageAcquisition(data: Data([2]), source: .network)
    }
}

private actor RetryOfflineImageAcquirer: OfflineCacheImageAcquiring {
    private(set) var requestedURLs: [URL] = []
    private let failingImageURL: URL
    private var shouldFail = true

    init(failingImageURL: URL) {
        self.failingImageURL = failingImageURL
    }

    func allowRetry() {
        shouldFail = false
        requestedURLs.removeAll()
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        requestedURLs.append(source.url)
        if source.url == failingImageURL, shouldFail {
            throw YamiboError.offline
        }
        return OfflineCacheImageAcquisition(data: source.url == failingImageURL ? Data([2]) : Data([1]), source: .network)
    }
}

private actor EmptyImageThenFailingAcquirer: OfflineCacheImageAcquiring {
    private(set) var requestedURLs: [URL] = []
    private let emptyImageURL: URL

    init(emptyImageURL: URL) {
        self.emptyImageURL = emptyImageURL
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        requestedURLs.append(source.url)
        if source.url == emptyImageURL {
            return OfflineCacheImageAcquisition(data: Data(), source: .network)
        }
        throw YamiboError.offline
    }
}

private actor CancelingOfflineImageAcquirer: OfflineCacheImageAcquiring {
    private let store: any TestOfflineCacheStoring
    private let workID: OfflineCacheWorkID

    init(store: any TestOfflineCacheStoring, workID: OfflineCacheWorkID) {
        self.store = store
        self.workID = workID
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        try await store.cancelOfflineCacheWork(id: workID)
        return OfflineCacheImageAcquisition(data: Data([1]), source: .network)
    }
}

private actor RecordingImageTransport: OfflineCacheImageTransporting {
    private(set) var requests: [YamiboImageSource] = []
    private let dataByURL: [URL: Data]

    init(dataByURL: [URL: Data]) {
        self.dataByURL = dataByURL
    }

    func downloadImageData(for source: YamiboImageSource) async throws -> Data {
        requests.append(source)
        guard let data = dataByURL[source.url] else {
            throw YamiboError.invalidResponse(statusCode: 404)
        }
        return data
    }
}

private actor RecordingQueueRunObserver: OfflineCacheQueueRunObserving {
    private(set) var submissionCount = 0
    private(set) var progressUpdates: [OfflineCacheProgress] = []
    private(set) var finishResults: [Bool] = []

    func submitUserInitiatedRun() async {
        submissionCount += 1
    }

    func queueRunDidUpdateProgress(completedImageCount: Int, targetImageCount: Int) async {
        progressUpdates.append(
            OfflineCacheProgress(
                completedUnitCount: completedImageCount,
                targetUnitCount: targetImageCount
            )
        )
    }

    func queueRunDidFinish(success: Bool) async {
        finishResults.append(success)
    }

    func queueRunDidCancel() async {
        finishResults.append(false)
    }
}

private actor RecordingNovelOfflineSourcePageLoader: NovelOfflineCacheSourcePageLoading {
    private(set) var requests: [NovelOfflineCacheWorkRequest] = []
    private var preparedPagesByEntryKey: [String: NovelOfflineCachePreparedSourcePage] = [:]

    func setPreparedPage(
        _ preparedPage: NovelOfflineCachePreparedSourcePage,
        for request: NovelOfflineCacheWorkRequest
    ) {
        preparedPagesByEntryKey[request.entryKey] = preparedPage
    }

    func loadNovelOfflineCacheSourcePage(
        _ request: NovelOfflineCacheWorkRequest
    ) async throws -> NovelOfflineCachePreparedSourcePage {
        requests.append(request)
        guard let preparedPage = preparedPagesByEntryKey[request.entryKey] else {
            throw YamiboError.parsingFailed(context: "Missing test novel offline source page")
        }
        return preparedPage
    }
}

private func makeExecutorWorkRequest(
    ownerName: String,
    tid: String,
    targetImageURLs: [URL]
) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        targetImageURLs: targetImageURLs
    )
}

private func makeNovelExecutorWorkRequest(
    tid: String,
    view: Int,
    retainsInlineImages: Bool,
    ownerTitle: String? = nil
) throws -> NovelOfflineCacheWorkRequest {
    NovelOfflineCacheWorkRequest(
        ownerTitle: ownerTitle ?? "小说\(tid)",
        title: "第\(view)页",
        threadID: tid,
        view: view,
        authorID: "42",
        retainsInlineImages: retainsInlineImages
    )
}

private func makeNovelExecutorPreparedSourcePage(
    tid: String,
    view: Int,
    imageURLs: [URL]
) throws -> NovelOfflineCachePreparedSourcePage {
    let segments = [.text("正文\(view)", chapterTitle: "第\(view)章")]
        + imageURLs.map { NovelReaderSegment.image($0, chapterTitle: nil) }
    let sourcePage = ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "小说\(tid)",
        posts: [
            ForumThreadPost(
                postID: "\(tid)-\(view)",
                author: BlogReaderUser(uid: "42", name: "楼主"),
                contentHTML: "<strong>第\(view)章</strong><br>正文\(view)",
                contentText: "正文\(view)",
                images: imageURLs.map { ForumThreadPostImage(url: $0.absoluteString) }
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: view, totalPages: max(2, view))
    )
    let document = NovelReaderProjection(
        threadID: tid,
        view: view,
        maxView: max(2, view),
        resolvedAuthorID: "42",
        segments: segments,
        projectionSourceFingerprint: "novel-\(tid)-\(view)",
        projectionSchemaVersion: 1
    )
    return NovelOfflineCachePreparedSourcePage(sourcePage: sourcePage, projection: document)
}

private func makeDocument(tid: String, imageURLs: [URL]) throws -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs
    )
}

private func makeImageURLs(tid: String, count: Int) throws -> [URL] {
    try (1...count).map { index in
        try #require(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
    }
}

private func makeTemporaryExecutorDirectory() throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while await condition() == false {
        if start.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
            throw YamiboError.underlying("Timed out waiting for condition")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
