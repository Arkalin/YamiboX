import Foundation
import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class OfflineCacheQueueViewModelTests: XCTestCase {
    func testQueueProjectsEntryCountGroupingOrderingProgressSpeedAndFailure() async throws {
        let fixture = try await makeQueueFixture()
        let activeImage = try XCTUnwrap(URL(string: "https://img.example.com/100-1.jpg"))
        let pendingImage = try XCTUnwrap(URL(string: "https://img.example.com/100-2.jpg"))
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品B", tid: "300")
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(
                ownerName: "作品A",
                tid: "200"
            )
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(
                ownerName: "作品A",
                tid: "100",
                targetImageURLs: [activeImage, pendingImage]
            )
        )
        try await fixture.offlineCacheStore.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "100",
            targetImageURLs: [activeImage, pendingImage],
            completedImageURLs: [activeImage],
            currentBytesPerSecond: 2048
        )
        try await fixture.offlineCacheStore.markOfflineCacheWorkFailed(
            ownerName: "作品A",
            tid: "200",
            message: "Timeout"
        )
        try await fixture.directoryStore.saveDirectory(
            MangaDirectory(
                cleanBookName: "作品A",
                strategy: .tag,
                sourceKey: "tag:1",
                chapters: [
                    try makeDirectoryChapter(tid: "100", chapterNumber: 1),
                    try makeDirectoryChapter(tid: "200", chapterNumber: 2)
                ]
            )
        )

        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.entryCount, 3)
        XCTAssertEqual(viewModel.groups.map(\.ownerName), ["作品B", "作品A"])
        XCTAssertEqual(viewModel.groups[1].chapters.map(\.tid), ["100", "200"])
        XCTAssertEqual(viewModel.groups[1].progressText, L10n.string("mine.offline_queue.image_progress_format", 1, 2))
        XCTAssertEqual(viewModel.groups[1].percentageText, L10n.string("mine.offline_queue.percent_format", 50))
        XCTAssertEqual(viewModel.groups[1].progressFraction, 0.5)
        XCTAssertEqual(viewModel.groups[1].failureStatusText, "Timeout")

        let activeRow = viewModel.groups[1].chapters[0]
        XCTAssertEqual(activeRow.completedImageCount, 1)
        XCTAssertEqual(activeRow.targetImageCount, 2)
        XCTAssertEqual(activeRow.percentageText, L10n.string("mine.offline_queue.percent_format", 50))
        XCTAssertNotNil(activeRow.speedText)
        XCTAssertEqual(viewModel.groups[1].currentSpeedText, activeRow.speedText)

        let failedRow = viewModel.groups[1].chapters[1]
        XCTAssertEqual(failedRow.failureStatusText, "Timeout")
    }

    func testQueueExcludesCompletedMembershipsFromEntryCount() async throws {
        let fixture = try await makeQueueFixture()
        let cachedImage = try XCTUnwrap(URL(string: "https://img.example.com/completed-100.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: cachedImage)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeOfflineCacheMembership(
                ownerName: "作品A",
                tid: "100",
                imageURLs: [cachedImage]
            )
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "200")
        )

        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.entryCount, 1)
        XCTAssertEqual(viewModel.groups.first?.chapters.map(\.tid), ["200"])
    }

    func testQueueModelsKeepMixedReaderOwnersSeparate() throws {
        let mangaGroupID = OfflineCacheGroupID(readerKind: .manga, ownerKey: "同名作品")
        let novelGroupID = OfflineCacheGroupID(readerKind: .novel, ownerKey: "同名作品")
        let projection = OfflineCacheQueueProjection.project(works: [
            makeOfflineQueueWork(
                readerKind: .manga,
                ownerKey: "同名作品",
                entryKey: "100",
                title: "漫画章节",
                insertionIndex: 1
            ),
            makeOfflineQueueWork(
                readerKind: .novel,
                ownerKey: "同名作品",
                entryKey: "novel-1",
                title: "小说章节",
                insertionIndex: 2
            )
        ])
        let groups = projection.groups.map(OfflineCacheQueueOwnerGroup.init(group:))

        XCTAssertEqual(groups.map(\.id), [mangaGroupID, novelGroupID])
        XCTAssertEqual(groups.map(\.ownerName), ["同名作品", "同名作品"])
        XCTAssertEqual(groups.flatMap(\.chapters).map(\.readerKind), [.manga, .novel])
    }

    func testQueueLoadsNovelWorkRowsFromStore() async throws {
        let fixture = try await makeQueueFixture()
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "漫画A", tid: "100")
        )
        _ = try await fixture.offlineCacheStore.enqueueNovelOfflineCacheWork(
            try makeNovelOfflineCacheWorkRequest(ownerTitle: "小说A", tid: "200", view: 1)
        )

        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.entryCount, 2)
        XCTAssertEqual(Set(viewModel.groups.map(\.readerKind)), [.manga, .novel])
        XCTAssertEqual(Set(viewModel.groups.map(\.ownerName)), ["漫画A", "小说A"])
        XCTAssertEqual(Set(viewModel.groups.flatMap(\.chapters).map(\.readerKind)), [.manga, .novel])
    }

    func testContinueQueueRetriesFailedNovelWork() async throws {
        let fixture = try await makeQueueFixture()
        let enqueueResult = try await fixture.offlineCacheStore.enqueueNovelOfflineCacheWork(
            try makeNovelOfflineCacheWorkRequest(ownerTitle: "小说A", tid: "200", view: 1)
        )
        let workID = try XCTUnwrap(enqueueResult.enqueuedWork?.id)
        try await fixture.offlineCacheStore.markOfflineCacheWorkFailed(id: workID, message: "Timeout")
        let controller = RecordingOfflineCacheQueueController(store: fixture.offlineCacheStore)
        let viewModel = OfflineCacheQueueViewModel(
            dependencies: fixture.appContext.accountDependencies,
            controller: controller
        )

        await viewModel.refresh()
        XCTAssertEqual(viewModel.groups.first?.chapters.first?.failureStatusText, "Timeout")

        await viewModel.continueQueue()

        let refreshedWork = await fixture.offlineCacheStore.offlineCacheQueueWorks().first { $0.id == workID }
        XCTAssertEqual(refreshedWork?.state, .queued)
        XCTAssertNil(refreshedWork?.failureMessage)
        XCTAssertNil(viewModel.groups.first?.chapters.first?.failureStatusText)
    }

    func testQueueAutomaticallyRefreshesWhenStoreProgressChanges() async throws {
        let fixture = try await makeQueueFixture()
        let firstImage = try XCTUnwrap(URL(string: "https://img.example.com/100-1.jpg"))
        let secondImage = try XCTUnwrap(URL(string: "https://img.example.com/100-2.jpg"))
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(
                ownerName: "作品A",
                tid: "100",
                targetImageURLs: [firstImage, secondImage]
            )
        )
        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)

        await viewModel.load()
        XCTAssertEqual(viewModel.groups.first?.chapters.first?.completedImageCount, 0)

        try await fixture.offlineCacheStore.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "100",
            targetImageURLs: [firstImage, secondImage],
            completedImageURLs: [firstImage],
            currentBytesPerSecond: 4096
        )

        try await waitForQueueCondition {
            viewModel.groups.first?.chapters.first?.completedImageCount == 1
        }
        let row = try XCTUnwrap(viewModel.groups.first?.chapters.first)
        XCTAssertEqual(row.completedImageCount, 1)
        XCTAssertEqual(row.targetImageCount, 2)
        XCTAssertEqual(row.percentageText, L10n.string("mine.offline_queue.percent_format", 50))
        XCTAssertNotNil(row.speedText)
    }

    func testLoadAutomaticallyRefreshesWhenStoreChanges() async throws {
        let fixture = try await makeQueueFixture()
        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)

        await viewModel.load()
        XCTAssertEqual(viewModel.entryCount, 0)

        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "100")
        )

        try await waitForQueueCondition {
            viewModel.entryCount == 1
                && viewModel.groups.first?.ownerName == "作品A"
        }
    }

    func testQueueEmptyStateHidesControls() async throws {
        let fixture = try await makeQueueFixture()
        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.entryCount, 0)
        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertFalse(viewModel.showsControls)
    }

    func testQueueCommandsUseQueueControllerAndRefreshProjection() async throws {
        let fixture = try await makeQueueFixture()
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "100")
        )
        let controller = RecordingOfflineCacheQueueController(store: fixture.offlineCacheStore)
        let viewModel = OfflineCacheQueueViewModel(
            dependencies: fixture.appContext.accountDependencies,
            controller: controller
        )

        await viewModel.refresh()
        let workID = try XCTUnwrap(viewModel.groups.first?.chapters.first?.id)
        await viewModel.continueQueue()
        await viewModel.pauseQueue()
        await viewModel.cancelChapter(workID)

        let events = await controller.snapshotEvents()
        let canceledWork = await fixture.offlineCacheStore.mangaQueueWork(ownerName: "作品A", tid: "100")
        XCTAssertEqual(events, ["continue", "pause", "cancel:作品A:100"])
        XCTAssertEqual(viewModel.entryCount, 0)
        XCTAssertNil(canceledWork)
    }

    func testOwnerGroupCancelPreservesCompletedCachedMembership() async throws {
        let fixture = try await makeQueueFixture()
        let cachedImage = try XCTUnwrap(URL(string: "https://img.example.com/100-1.jpg"))
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "200")
        )
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: cachedImage)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeOfflineCacheMembership(
                ownerName: "作品A",
                tid: "100",
                imageURLs: [cachedImage]
            )
        )
        let controller = RecordingOfflineCacheQueueController(store: fixture.offlineCacheStore)
        let viewModel = OfflineCacheQueueViewModel(
            dependencies: fixture.appContext.accountDependencies,
            controller: controller
        )

        await viewModel.cancelOwnerGroup(id: mangaOfflineGroupID("作品A"))

        let canceledWork = await fixture.offlineCacheStore.mangaQueueWork(ownerName: "作品A", tid: "200")
        let completedMembership = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "100")
        XCTAssertNil(canceledWork)
        XCTAssertNotNil(completedMembership)
        XCTAssertEqual(viewModel.entryCount, 0)
    }

    func testSelectionModeBatchCancelsSelectedWork() async throws {
        let fixture = try await makeQueueFixture()
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "100")
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "200")
        )
        let controller = RecordingOfflineCacheQueueController(store: fixture.offlineCacheStore)
        let viewModel = OfflineCacheQueueViewModel(
            dependencies: fixture.appContext.accountDependencies,
            controller: controller
        )
        await viewModel.refresh()
        let selectedIDs = viewModel.groups
            .flatMap(\.chapters)
            .filter { $0.ownerName == "作品A" && ["100", "200"].contains($0.tid) }
            .map(\.id)

        viewModel.setSelectionMode(true)
        for id in selectedIDs {
            viewModel.toggleWorkSelection(id)
        }
        await viewModel.cancelSelectedWorks()

        let events = await controller.snapshotEvents()
        XCTAssertEqual(Set(events), ["cancel:作品A:100", "cancel:作品A:200"])
        XCTAssertFalse(viewModel.isSelectionMode)
        XCTAssertTrue(viewModel.selectedWorkIDs.isEmpty)
        XCTAssertEqual(viewModel.entryCount, 0)
    }

    func testSelectionModeTogglesWholeOwnerGroup() async throws {
        let fixture = try await makeQueueFixture()
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "100")
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "200")
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "作品B", tid: "300")
        )
        let viewModel = OfflineCacheQueueViewModel(dependencies: fixture.appContext.accountDependencies)
        await viewModel.refresh()
        let ownerAWorkIDs = Set(
            viewModel.groups
                .first { $0.ownerName == "作品A" }?
                .chapters
                .map(\.id) ?? []
        )

        viewModel.toggleOwnerSelection(id: mangaOfflineGroupID("作品A"))

        XCTAssertTrue(viewModel.isOwnerSelected(id: mangaOfflineGroupID("作品A")))
        XCTAssertFalse(viewModel.isOwnerSelected(id: mangaOfflineGroupID("作品B")))
        XCTAssertEqual(viewModel.selectedWorkIDs, ownerAWorkIDs)

        viewModel.toggleOwnerSelection(id: mangaOfflineGroupID("作品A"))

        XCTAssertFalse(viewModel.isOwnerSelected(id: mangaOfflineGroupID("作品A")))
        XCTAssertTrue(viewModel.selectedWorkIDs.isEmpty)
    }
}

private struct OfflineCacheQueueFixture {
    let appContext: YamiboAppContext
    let offlineCacheStore: any TestOfflineCacheStoring
    let directoryStore: MangaDirectoryStore
}

private func makeQueueFixture() async throws -> OfflineCacheQueueFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "offline-cache-queue-view-model")
    let sessionStore = try SessionStore(testSuiteName: defaultsSuiteName, key: "session")
    let profileStore = try YamiboProfileStore(testSuiteName: defaultsSuiteName, key: "profile")
    let checkInStore = YamiboCheckInStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        keyPrefix: "check-in"
    )
    let offlineCacheRoot = makeTemporaryDirectory()
    let database = try YamiboDatabase.openPool(rootDirectory: offlineCacheRoot)
    let offlineCacheStore = OfflineCacheStore(
        databasePool: database,
        baseDirectory: offlineCacheRoot.appendingPathComponent("offline-images", isDirectory: true)
    )
    let directoryStore = MangaDirectoryStore(databasePool: database)

    let appContext = YamiboAppContext(
        sessionStore: sessionStore,
        profileStore: profileStore,
        checkInStore: checkInStore,
        mangaDirectoryStore: directoryStore,
        offlineCacheStore: offlineCacheStore,
        session: URLSession(configuration: .ephemeral)
    )
    return OfflineCacheQueueFixture(
        appContext: appContext,
        offlineCacheStore: offlineCacheStore,
        directoryStore: directoryStore
    )
}

private actor RecordingOfflineCacheQueueController: OfflineCacheQueueControlling {
    private let store: any TestOfflineCacheStoring
    private var recordedEvents: [String] = []

    func snapshotEvents() -> [String] {
        recordedEvents
    }

    init(store: any TestOfflineCacheStoring) {
        self.store = store
    }

    func continueQueue() async throws {
        recordedEvents.append("continue")
        try await store.retryFailedOfflineCacheWorks()
        try await store.setOfflineCacheQueueRunState(.running)
    }

    func pauseQueue() async throws {
        recordedEvents.append("pause")
        try await store.setOfflineCacheQueueRunState(.paused)
    }

    func cancelWork(id: OfflineCacheWorkID) async throws {
        if let work = await store.mangaQueueWorks().first(where: { $0.workID == id.rawValue }) {
            recordedEvents.append("cancel:\(work.ownerName):\(work.tid)")
        } else {
            recordedEvents.append("cancel:\(id.readerKind.rawValue):\(id.rawValue)")
        }
        try await store.cancelOfflineCacheWork(id: id)
    }

    func cancelGroup(id: OfflineCacheGroupID) async throws {
        recordedEvents.append("cancel-group:\(id.ownerKey)")
        try await store.cancelOfflineCacheGroup(id)
    }
}

private func makeOfflineQueueWork(
    readerKind: OfflineCacheReaderKind,
    ownerKey: String,
    entryKey: String,
    title: String,
    insertionIndex: Int
) -> OfflineCacheQueueWorkProjection {
    let groupID = OfflineCacheGroupID(readerKind: readerKind, ownerKey: ownerKey)
    let entryID = OfflineCacheEntryID(readerKind: readerKind, ownerKey: ownerKey, entryKey: entryKey)
    return OfflineCacheQueueWorkProjection(
        id: OfflineCacheWorkID(readerKind: readerKind, rawValue: "\(readerKind.rawValue)-\(entryKey)"),
        groupID: groupID,
        entryID: entryID,
        ownerTitle: ownerKey,
        title: title,
        progress: OfflineCacheProgress(completedUnitCount: 0, targetUnitCount: 1),
        state: .queued,
        failureMessage: nil,
        currentBytesPerSecond: 0,
        insertionIndex: insertionIndex
    )
}

private func makeNovelOfflineCacheWorkRequest(
    ownerTitle: String,
    tid: String,
    view: Int
) throws -> NovelOfflineCacheWorkRequest {
    NovelOfflineCacheWorkRequest(
        ownerTitle: ownerTitle,
        title: "第\(view)页",
        threadID: tid,
        view: view,
        targetImageURLs: []
    )
}

private func makeOfflineCacheWorkRequest(
    ownerName: String,
    tid: String,
    targetImageURLs: [URL] = []
) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        targetImageURLs: targetImageURLs
    )
}

private func makeOfflineCacheMembership(
    ownerName: String,
    tid: String,
    imageURLs: [URL]
) throws -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs,
        sourcePage: makeOfflineSourcePage(tid: tid)
    )
}

private func makeOfflineSourcePage(tid: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: "",
                contentText: ""
            )
        ]
    )
}

private func makeDirectoryChapter(tid: String, chapterNumber: Double) throws -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: "第\(tid)话",
        chapterNumber: chapterNumber
    )
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func waitForQueueCondition(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    try await waitForMainActorCondition(
        timeout: .nanoseconds(Int64(timeoutNanoseconds)),
        pollInterval: .milliseconds(10),
        condition
    )
}
