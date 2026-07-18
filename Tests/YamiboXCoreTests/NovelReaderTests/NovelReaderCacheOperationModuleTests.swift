import Foundation
import XCTest
@testable import YamiboXCore
import YamiboXTestSupport

@MainActor
final class NovelReaderCacheOperationModuleTests: XCTestCase {
    func testSelectionStateSeparatesCachedUncachedAndInvalidViews() {
        let module = NovelReaderCacheOperationModule()
        let selection = module.selectionState(
            for: [0, 1, 2, 4],
            snapshot: makeSnapshot(cacheableViews: [1, 2, 3], cachedViews: [1, 3])
        )

        XCTAssertEqual(selection.selectedViews, [1, 2])
        XCTAssertEqual(selection.cachedSelectedViews, [1])
        XCTAssertEqual(selection.uncachedSelectedViews, [2])
        XCTAssertTrue(selection.canCache)
        XCTAssertTrue(selection.canUpdate)
        XCTAssertTrue(selection.canDelete)
        XCTAssertFalse(selection.isAllSelected)
    }

    func testSelectionStateReportsAllSelectedOnlyForValidCompleteSelection() {
        let module = NovelReaderCacheOperationModule()
        let selection = module.selectionState(
            for: [1, 2, 3, 99],
            snapshot: makeSnapshot(cacheableViews: [1, 2, 3], cachedViews: [1])
        )

        XCTAssertEqual(selection.selectedViews, [1, 2, 3])
        XCTAssertTrue(selection.isAllSelected)
    }

    func testSelectionStateTreatsUnfinishedWorkAsCachingBeforeCacheOrUpdate() {
        let module = NovelReaderCacheOperationModule()
        let selection = module.selectionState(
            for: [1, 2, 3],
            snapshot: NovelReaderCacheOperationSnapshot(
                cacheableViews: [1, 2, 3],
                cachedViews: [1],
                cachingViews: [1, 2],
                context: NovelReaderCacheOperationContext(
                    threadID: "1",
                    authorID: "42"
                )
            )
        )

        XCTAssertEqual(selection.cachedSelectedViews, [1])
        XCTAssertEqual(selection.cachingSelectedViews, [1, 2])
        XCTAssertEqual(selection.updatableSelectedViews, [])
        XCTAssertEqual(selection.uncachedSelectedViews, [3])
        XCTAssertTrue(selection.canCache)
        XCTAssertFalse(selection.canUpdate)
        XCTAssertTrue(selection.canDelete)
    }

    func testStartCachingUpdatesProgressAndCompletion() async throws {
        let repository = FakeCacheOperationRepository(cachedViews: [1])
        let module = NovelReaderCacheOperationModule()
        module.syncCachedViews([1])

        module.startCaching(
            views: [1, 2, 3],
            snapshot: makeSnapshot(cacheableViews: [1, 2, 3], cachedViews: [1]),
            repository: repository,
            summary: { _, result in "done \(result.completedViews.count)" }
        )

        XCTAssertTrue(module.state.isRunning)
        XCTAssertEqual(module.state.queuedViews, [2, 3])

        try await waitFor {
            module.state.isFinished
        }

        XCTAssertEqual(module.cachedViews, [1, 2, 3])
        XCTAssertEqual(module.state.status, .completed)
        XCTAssertEqual(module.state.completedViews, [2, 3])
        XCTAssertEqual(module.state.summaryMessage, "done 2")
    }

    func testStopCachingCancelsRemainingQueueButKeepsCompletedViews() async throws {
        let repository = FakeCacheOperationRepository(cachedViews: [1], delayNanoseconds: 40_000_000)
        let module = NovelReaderCacheOperationModule()
        module.syncCachedViews([1])

        module.startCaching(
            views: [2, 3, 4],
            snapshot: makeSnapshot(cacheableViews: [1, 2, 3, 4], cachedViews: [1]),
            repository: repository,
            summary: { _, result in result.wasCancelled ? "cancelled" : "completed" }
        )

        try await Task.sleep(nanoseconds: 60_000_000)
        module.stopCaching()

        try await waitFor {
            module.state.isFinished
        }

        XCTAssertEqual(module.state.status, .cancelled)
        XCTAssertLessThan(module.state.completedViews.count, 3)
        XCTAssertTrue(module.cachedViews.isSuperset(of: [1]))
    }

    func testUpdateCachedViewsRewritesOnlySelectedCachedViews() async throws {
        let repository = FakeCacheOperationRepository(cachedViews: [1, 2])
        let module = NovelReaderCacheOperationModule()
        module.syncCachedViews([1, 2])

        module.updateCachedViews(
            [1, 3],
            snapshot: makeSnapshot(cacheableViews: [1, 2, 3], cachedViews: [1, 2]),
            repository: repository,
            summary: { _, result in "updated \(result.completedViews.count)" }
        )

        try await waitFor {
            module.state.isFinished
        }

        let deletedViews = await repository.deletedViews
        let cachedBatches = await repository.cachedBatches
        let updatedBatches = await repository.updatedBatches
        XCTAssertEqual(deletedViews, [])
        XCTAssertEqual(cachedBatches, [])
        XCTAssertEqual(updatedBatches, [[1]])
        XCTAssertEqual(module.cachedViews, [1, 2])
        XCTAssertEqual(module.state.status, .completed)
        XCTAssertEqual(module.state.completedViews, [1])
    }

    func testRepositoryReceivesSnapshotContextForCacheUpdateDeleteAndRefresh() async throws {
        let context = NovelReaderCacheOperationContext(
            threadID: "42",
            authorID: "42"
        )
        let snapshot = NovelReaderCacheOperationSnapshot(
            cacheableViews: [1, 2, 3],
            cachedViews: [1],
            context: context
        )
        let repository = FakeCacheOperationRepository(cachedViews: [1])
        let module = NovelReaderCacheOperationModule()
        module.syncCachedViews([1])

        module.startCaching(
            views: [2],
            snapshot: snapshot,
            repository: repository,
            summary: { _, _ in "cached" }
        )
        try await waitFor { module.state.isFinished }

        module.updateCachedViews(
            [1],
            snapshot: snapshot,
            repository: repository,
            summary: { _, _ in "updated" }
        )
        try await waitFor { module.state.isFinished && module.state.summaryMessage == "updated" }

        try await module.deleteCachedViews([1], snapshot: snapshot, repository: repository)

        let contexts = await repository.receivedContexts
        XCTAssertFalse(contexts.isEmpty)
        XCTAssertTrue(contexts.allSatisfy { $0 == context })
    }

    func testOfflineStoreAdapterRecordsRetainInlineImagesSettingWhenEnqueuing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-cache-operation-adapter-\(UUID().uuidString)", isDirectory: true)
        let database = try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("grdb", isDirectory: true))
        let store = OfflineCacheStore(
            databasePool: database,
            baseDirectory: root.appendingPathComponent("offline-cache", isDirectory: true)
        )
        let adapter = NovelOfflineStoreReaderCacheOperationAdapter(
            store: store,
            novelOfflineCacheSettings: {
                NovelOfflineCacheSettings(retainsInlineImages: true)
            }
        )
        let context = NovelReaderCacheOperationContext(
            ownerTitle: "小说A",
            threadID: "8848",
            authorID: "42"
        )

        let result = await adapter.cacheViews([1], for: context, progress: nil)
        let work = await store.nextOfflineCacheProcessingWork()

        XCTAssertEqual(result.completedViews, [1])
        XCTAssertTrue(work?.retainsInlineImages == true)
    }

    private func makeSnapshot(
        cacheableViews: Set<Int>,
        cachedViews: Set<Int>
    ) -> NovelReaderCacheOperationSnapshot {
        NovelReaderCacheOperationSnapshot(
            cacheableViews: cacheableViews,
            cachedViews: cachedViews,
            context: NovelReaderCacheOperationContext(
                threadID: "1",
                authorID: nil
            )
        )
    }
}

private actor FakeCacheOperationRepository: NovelReaderCacheOperationRepository {
    private(set) var deletedViews: [Set<Int>] = []
    private(set) var cachedBatches: [Set<Int>] = []
    private(set) var updatedBatches: [Set<Int>] = []
    private(set) var receivedContexts: [NovelReaderCacheOperationContext] = []
    private var storedCachedViews: Set<Int>
    private let delayNanoseconds: UInt64

    init(cachedViews: Set<Int>, delayNanoseconds: UInt64 = 0) {
        self.storedCachedViews = cachedViews
        self.delayNanoseconds = delayNanoseconds
    }

    func cacheState(for context: NovelReaderCacheOperationContext) async -> NovelOfflineCacheViewsSnapshot {
        receivedContexts.append(context)
        return NovelOfflineCacheViewsSnapshot(cachedViews: storedCachedViews)
    }

    func cachedViews(for context: NovelReaderCacheOperationContext) async -> Set<Int> {
        receivedContexts.append(context)
        return storedCachedViews
    }

    func deleteCachedViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext
    ) async throws {
        receivedContexts.append(context)
        deletedViews.append(views)
        storedCachedViews.subtract(views)
    }

    func cacheViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        progress: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)?
    ) async -> NovelReaderCacheBatchResult {
        receivedContexts.append(context)
        let targets = views.sorted()
        cachedBatches.append(Set(targets))
        var completedViews: [Int] = []
        var wasCancelled = false

        for view in targets {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    wasCancelled = true
                    break
                }
            }
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            completedViews.append(view)
            storedCachedViews.insert(view)
            await progress?(NovelReaderCacheBatchProgress(
                totalCount: targets.count,
                completedCount: completedViews.count,
                currentView: view,
                completedViews: completedViews,
                failedViews: [],
                status: .running
            ))
        }

        await progress?(NovelReaderCacheBatchProgress(
            totalCount: targets.count,
            completedCount: completedViews.count,
            currentView: nil,
            completedViews: completedViews,
            failedViews: [],
            status: wasCancelled ? .cancelled : .completed
        ))
        return NovelReaderCacheBatchResult(
            totalCount: targets.count,
            completedViews: completedViews,
            failedViews: [],
            wasCancelled: wasCancelled
        )
    }

    func updateCachedViews(
        _ views: Set<Int>,
        for context: NovelReaderCacheOperationContext,
        progress: (@Sendable (NovelReaderCacheBatchProgress) async -> Void)?
    ) async -> NovelReaderCacheBatchResult {
        receivedContexts.append(context)
        let targets = views.sorted()
        updatedBatches.append(Set(targets))
        await progress?(NovelReaderCacheBatchProgress(
            totalCount: targets.count,
            completedCount: targets.count,
            currentView: nil,
            completedViews: targets,
            failedViews: [],
            status: .completed
        ))
        return NovelReaderCacheBatchResult(
            totalCount: targets.count,
            completedViews: targets,
            failedViews: [],
            wasCancelled: false
        )
    }
}

@MainActor
private func waitFor(
    timeout: TimeInterval = 2,
    intervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    do {
        try await waitForCondition(
            timeout: .seconds(timeout),
            pollInterval: .nanoseconds(Int64(intervalNanoseconds))
        ) { await condition() }
    } catch is TestWaitTimeoutError {
        XCTFail("Timed out waiting for condition")
    }
}
