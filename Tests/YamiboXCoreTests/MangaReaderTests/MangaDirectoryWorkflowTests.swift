import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Directory Workflow")
struct MangaDirectoryWorkflowTests {
    @Test func initialDirectoryReusesNameThenTIDBeforeSeeding() async throws {
        let named = makeDirectory(name: "命名目录", strategy: .searched, sourceKey: "named", tids: ["900"])
        let containing = makeDirectory(name: "包含目录", strategy: .searched, sourceKey: "containing", tids: ["700"])
        let store = RecordingDirectoryStore(directories: [named, containing])
        let repository = RecordingDirectoryRepository(seed: makeSeed(tid: "700", tagIDs: ["31"]))
        let workflow = MangaDirectoryWorkflow(repository: repository, store: store)
        let document = try makeDocument(tid: "700")
        let context = try makeContext(tid: "700", directoryName: " 命名目录 ")

        let resolvedByName = try await workflow.resolveInitialDirectory(context: context, projection: document)
        #expect(resolvedByName.directory.cleanBookName == "命名目录")
        #expect(!resolvedByName.shouldAutoUpdateAfterInitialLoad)
        #expect(await repository.seedThreadIDs.isEmpty)
        #expect(await store.savedDirectories.isEmpty)

        let missingContext = try makeContext(tid: "700", directoryName: "missing")
        let resolvedByTID = try await workflow.resolveInitialDirectory(context: missingContext, projection: document)
        #expect(resolvedByTID.directory.cleanBookName == "包含目录")
        #expect(await repository.seedThreadIDs.isEmpty)
    }

    @Test func initialTagDirectoryIsSeededAndMarkedForDeferredRefresh() async throws {
        let store = RecordingDirectoryStore()
        let repository = RecordingDirectoryRepository(
            seed: makeSeed(tid: "700", tagIDs: [" 31 ", "", "31"])
        )
        let workflow = MangaDirectoryWorkflow(repository: repository, store: store)
        let context = try makeContext(tid: "700")
        let document = try makeDocument(tid: "700")

        let resolved = try await workflow.resolveInitialDirectory(context: context, projection: document)

        #expect(resolved.directory.strategy == .tag)
        #expect(resolved.directory.sourceKey == "31")
        #expect(resolved.shouldAutoUpdateAfterInitialLoad)
        #expect(await repository.seedThreadIDs == [context.chapterTID])
        #expect(await store.savedDirectories.map(\.cleanBookName) == ["测试漫画"])
    }

    @Test func tagUpdateMergesRemoteChaptersAndOffersForcedSearchShortcut() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let directory = makeDirectory(name: "测试漫画", strategy: .tag, sourceKey: "31", tids: ["700"])
        let store = RecordingDirectoryStore(directories: [directory])
        let repository = RecordingDirectoryRepository(
            seed: makeSeed(tid: "700"),
            tagChapters: [makeChapter(tid: "701", title: "第2话")]
        )
        let workflow = MangaDirectoryWorkflow(
            repository: repository,
            store: store,
            configuration: MangaDirectoryWorkflowConfiguration(now: { now })
        )

        let result = try await workflow.updateDirectory(directory, currentTID: "700")

        #expect(result.directory.strategy == .tag)
        #expect(result.directory.chapters.map(\.tid) == ["700", "701"])
        #expect(result.directory.lastUpdatedAt == now)
        #expect(!result.searchPerformed)
        #expect(result.shouldOfferForcedSearch)
        #expect(result.cooldownExpiresAt == nil)
        #expect(await repository.tagDirectoryRequests.map(\.tagIDs) == [["31"]])
        #expect(await repository.searchRequests.isEmpty)
    }

    @Test func tagUpdatePrunesExistingNonChapterRowsFilteredFromRemoteTag() async throws {
        let directory = makeDirectory(
            name: "因为今天女友不在",
            strategy: .tag,
            sourceKey: "20013",
            chapters: [
                makeChapter(tid: "518460", title: "01"),
                makeChapter(tid: "568431", title: "【提灯喵汉化组】因为今天女友不在 37"),
                makeChapter(tid: "570528", title: "香询问大家因为今天女友不在的漫画价格"),
            ],
            searchKeyword: "提灯喵汉化组 因为今天女友不在"
        )
        let store = RecordingDirectoryStore(directories: [directory])
        let repository = RecordingDirectoryRepository(
            seed: makeSeed(tid: "568431"),
            tagChapters: [
                makeChapter(tid: "568431", title: "【提灯喵汉化组】因为今天女友不在 37"),
                makeChapter(tid: "571415", title: "【提灯喵汉化组】因为今天女友不在 38"),
            ]
        )
        let workflow = MangaDirectoryWorkflow(repository: repository, store: store)

        let result = try await workflow.updateDirectory(directory, currentTID: "568431")

        #expect(result.directory.chapters.map(\.tid) == ["518460", "568431", "571415"])
    }

    @Test func emptyTagUpdateFallsBackToSearchAndStartsCooldown() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let directory = makeDirectory(
            name: "测试漫画",
            strategy: .tag,
            sourceKey: "31",
            chapters: [makeChapter(tid: "700", title: "【作者】测试漫画 第1话")]
        )
        let store = RecordingDirectoryStore(directories: [directory])
        let repository = RecordingDirectoryRepository(
            seed: makeSeed(tid: "700"),
            tagChapters: [],
            searchChapters: [makeChapter(tid: "702", title: "第3话")]
        )
        let cooldown = MangaDirectorySearchCooldownState()
        // A non-default board fid: the configured `searchForumID` must reach
        // both the tag-list filter and the fallback search unchanged
        // (pluggable-reader-config decision #6 — the value is stamped per
        // launch from the thread's own board, no longer always "30").
        let workflow = MangaDirectoryWorkflow(
            repository: repository,
            store: store,
            configuration: MangaDirectoryWorkflowConfiguration(searchForumID: "46", now: { now }),
            searchCooldownState: cooldown
        )

        let result = try await workflow.updateDirectory(directory, currentTID: "700")

        #expect(result.directory.strategy == .tag)
        #expect(result.directory.chapters.map(\.tid) == ["700", "702"])
        #expect(result.searchPerformed)
        #expect(!result.shouldOfferForcedSearch)
        #expect(result.cooldownExpiresAt == now.addingTimeInterval(20))
        #expect(await cooldown.cooldownExpiresAt(now: now) == now.addingTimeInterval(20))
        #expect(await repository.tagDirectoryRequests.map(\.allowedForumID) == ["46"])
        #expect(await repository.searchRequests.map(\.forumID) == ["46"])
        #expect(await repository.searchRequests.first?.keyword == "作者 测试漫画")
    }

    /// Reset must discard the locally cached chapter list (including any
    /// manual correction like the "999" chapter here) and rebuild it from a
    /// fresh network seed, while keeping the directory's existing
    /// `cleanBookName` identity even though the freshly fetched seed derives
    /// a different one — otherwise a reset would silently orphan whatever
    /// other subsystem (favorites, reading progress) keys off that name.
    @Test func resetDirectoryReseedsFromNetworkDiscardingStaleChaptersButPreservesIdentity() async throws {
        let directory = makeDirectory(
            name: "自定义命名",
            strategy: .searched,
            sourceKey: "旧来源",
            chapters: [
                makeChapter(tid: "700", title: "第1话", chapterNumber: 1),
                makeChapter(tid: "999", title: "手动新增的章节", chapterNumber: 99),
            ],
            searchKeyword: "自定义关键词"
        )
        let store = RecordingDirectoryStore(directories: [directory])
        let repository = RecordingDirectoryRepository(
            seed: makeSeed(tid: "700", tagIDs: ["31"]),
            tagChapters: [makeChapter(tid: "701", title: "第2话")]
        )
        let workflow = MangaDirectoryWorkflow(repository: repository, store: store)

        let result = try await workflow.resetDirectory(directory, seedTID: "700")

        #expect(result.directory.cleanBookName == "自定义命名")
        #expect(result.directory.strategy == .tag)
        #expect(result.directory.sourceKey == "31")
        #expect(result.directory.chapters.map(\.tid) == ["700", "701"])
        #expect(!result.directory.chapters.contains(where: { $0.tid == "999" }))
        #expect(result.shouldOfferForcedSearch)
        #expect(await repository.seedThreadIDs == ["700"])
        #expect(await repository.tagDirectoryRequests.map(\.tagIDs) == [["31"]])
    }

    @Test func forcedSearchBypassesTagAndUsesTypedCooldownError() async throws {
        let firstNow = Date(timeIntervalSince1970: 3_000)
        let secondNow = Date(timeIntervalSince1970: 3_005)
        let dateProvider = ManualDateProvider(now: firstNow)
        let directory = makeDirectory(name: "测试漫画", strategy: .tag, sourceKey: "31", tids: ["700"])
        let store = RecordingDirectoryStore(directories: [directory])
        let repository = RecordingDirectoryRepository(
            seed: makeSeed(tid: "700"),
            tagChapters: [makeChapter(tid: "701", title: "第2话")],
            searchChapters: [makeChapter(tid: "703", title: "第4话")]
        )
        let workflow = MangaDirectoryWorkflow(
            repository: repository,
            store: store,
            configuration: MangaDirectoryWorkflowConfiguration(now: { dateProvider.now }),
            searchCooldownState: MangaDirectorySearchCooldownState()
        )

        _ = try await workflow.updateDirectory(directory, currentTID: "700", isForcedSearch: true)
        dateProvider.now = secondNow

        await #expect(throws: YamiboError.searchCooldown(seconds: 15)) {
            _ = try await workflow.updateDirectory(directory, currentTID: "700", isForcedSearch: true)
        }
        #expect(await repository.tagDirectoryRequests.isEmpty)
        #expect(await repository.searchRequests.count == 1)
    }

    /// Regression guard: the cooldown gate must be reserved BEFORE the
    /// network call, not after a successful one — otherwise a search that
    /// fails (e.g. the forum's own flood control) leaves the gate unarmed
    /// and the very next attempt repeats the same live request against a
    /// forum that just rate-limited it.
    @Test func searchFailureStillArmsCooldownSoTheNextAttemptIsRejectedWithoutHittingTheNetworkAgain() async throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let directory = makeDirectory(name: "测试漫画", strategy: .searched, sourceKey: "测试漫画", tids: ["700"])
        let store = RecordingDirectoryStore(directories: [directory])
        let repository = RecordingDirectoryRepository(seed: makeSeed(tid: "700"), searchError: YamiboError.floodControl)
        let workflow = MangaDirectoryWorkflow(
            repository: repository,
            store: store,
            configuration: MangaDirectoryWorkflowConfiguration(now: { now })
        )

        await #expect(throws: YamiboError.floodControl) {
            _ = try await workflow.updateDirectory(directory, currentTID: "700")
        }
        #expect(await repository.searchRequests.count == 1)

        await #expect(throws: YamiboError.searchCooldown(seconds: 20)) {
            _ = try await workflow.updateDirectory(directory, currentTID: "700")
        }
        #expect(await repository.searchRequests.count == 1, "the second attempt must be rejected by the cooldown gate before it ever reaches the network")
    }

    /// Regression guard: two callers racing `reserveCooldown` for the same
    /// window must never both win — exactly one arms the cooldown, and the
    /// other observes that reservation instead of independently deciding
    /// no cooldown is active.
    @Test func reserveCooldownIsAtomicUnderConcurrentCallers() async throws {
        let state = MangaDirectorySearchCooldownState()
        let now = Date(timeIntervalSince1970: 10_000)

        async let first = state.reserveCooldown(now: now, duration: 20)
        async let second = state.reserveCooldown(now: now, duration: 20)
        let results = await [first, second]

        let winners = results.filter { $0 == nil }
        let losers = results.compactMap { $0 }
        #expect(winners.count == 1, "exactly one caller must win the reservation")
        #expect(losers.count == 1, "the other caller must lose and see the winner's deadline")
        #expect(losers.first == now.addingTimeInterval(20))
    }

    @Test func renameMergesIntoExistingTargetAndKeepsTargetSource() async throws {
        let now = Date(timeIntervalSince1970: 4_000)
        let current = makeDirectory(name: "旧标题", strategy: .searched, sourceKey: "旧标题", tids: ["700", "701"])
        let target = makeDirectory(name: "新标题", strategy: .tag, sourceKey: "31", tids: ["701", "702"])
        let store = RecordingDirectoryStore(directories: [current, target])
        let workflow = MangaDirectoryWorkflow(
            repository: RecordingDirectoryRepository(seed: makeSeed(tid: "700")),
            store: store,
            configuration: MangaDirectoryWorkflowConfiguration(now: { now })
        )

        let renamed = try await workflow.renameDirectory(
            current,
            cleanBookName: " 新标题 ",
            searchKeyword: " 作者 新标题 "
        )

        #expect(renamed.cleanBookName == "新标题")
        #expect(renamed.strategy == .tag)
        #expect(renamed.sourceKey == "31")
        #expect(renamed.searchKeyword == "作者 新标题")
        #expect(renamed.lastUpdatedAt == now)
        #expect(renamed.chapters.map(\.tid) == ["700", "701", "702"])
        #expect(await store.deletedNames == ["旧标题"])
    }

    @Test func renameUsesTransactionalStoreCapabilityWhenAvailable() async throws {
        let current = makeDirectory(name: "旧标题", strategy: .searched, sourceKey: "旧标题", tids: ["700"])
        let store = RecordingRenamingDirectoryStore(directories: [current])
        let workflow = MangaDirectoryWorkflow(
            repository: RecordingDirectoryRepository(seed: makeSeed(tid: "700")),
            store: store
        )

        let renamed = try await workflow.renameDirectory(
            current,
            cleanBookName: "新标题",
            searchKeyword: ""
        )

        #expect(renamed.cleanBookName == "新标题")
        #expect(await store.renameRequests.map(\.oldName) == ["旧标题"])
        #expect(await store.savedDirectories.isEmpty)
        #expect(await store.deletedNames.isEmpty)
        #expect(try await store.directory(named: "旧标题") == nil)
        #expect(try await store.directory(named: "新标题")?.chapters.map(\.tid) == ["700"])
    }

    @Test func editDraftPreservesNameAndSplitsExistingKeyword() {
        let directory = makeDirectory(
            name: "作品",
            strategy: .searched,
            sourceKey: "作品",
            chapters: [makeChapter(tid: "700", title: "【作者】作品 第1话")],
            searchKeyword: "作者 作品"
        )
        let workflow = MangaDirectoryWorkflow(
            repository: RecordingDirectoryRepository(seed: makeSeed(tid: "700")),
            store: RecordingDirectoryStore()
        )

        let draft = workflow.editDraft(for: directory, currentTID: "700")

        #expect(draft.cleanBookName == "作品")
        #expect(draft.primaryKeyword == "作者")
        #expect(draft.secondaryKeyword == "作品")
        #expect(MangaDirectoryWorkflow.searchKeyword(from: draft) == "作者 作品")
    }

    @Test func mergeAndSortDeduplicatesAndInfersMissingChapterNumbers() {
        let existing = [
            makeChapter(tid: "701", title: "第2话", chapterNumber: 2),
            makeChapter(tid: "700", title: "第1话", chapterNumber: 1)
        ]
        let incoming = [
            makeChapter(tid: "701", title: "第2话 修订", chapterNumber: 2),
            makeChapter(tid: "702", title: "幕间", chapterNumber: 0)
        ]

        let merged = MangaDirectoryMerge.mergeAndSort(existing, incoming)

        #expect(merged.map(\.tid) == ["700", "701", "702"])
        #expect(merged[1].rawTitle == "第2话 修订")
        #expect(merged[2].chapterNumber == 2.1)
    }
}

private actor RecordingDirectoryRepository: MangaDirectoryRepository {
    private let seed: MangaDirectorySeed
    private let tagChapters: [MangaChapter]
    private let searchChapters: [MangaChapter]
    private let searchError: Error?
    private(set) var seedThreadIDs: [String] = []
    private(set) var tagDirectoryRequests: [(tagIDs: [String], allowedForumID: String)] = []
    private(set) var searchRequests: [(keyword: String, forumID: String)] = []

    init(
        seed: MangaDirectorySeed,
        tagChapters: [MangaChapter] = [],
        searchChapters: [MangaChapter] = [],
        searchError: Error? = nil
    ) {
        self.seed = seed
        self.tagChapters = tagChapters
        self.searchChapters = searchChapters
        self.searchError = searchError
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        seedThreadIDs.append(threadID)
        return seed
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        tagDirectoryRequests.append((tagIDs, allowedForumID))
        return tagChapters
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        searchRequests.append((keyword, forumID))
        if let searchError { throw searchError }
        return searchChapters
    }
}

private final class ManualDateProvider: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private actor RecordingDirectoryStore: MangaDirectoryPersisting {
    private var directories: [String: MangaDirectory]
    private(set) var savedDirectories: [MangaDirectory] = []
    private(set) var deletedNames: [String] = []

    init(directories: [MangaDirectory] = []) {
        self.directories = Dictionary(uniqueKeysWithValues: directories.map { ($0.cleanBookName, $0) })
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories[name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.values.first { directory in
            directory.chapters.contains { $0.tid == tid.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        savedDirectories.append(directory)
        directories[directory.cleanBookName] = directory
    }

    func deleteDirectory(named name: String) async throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deletedNames.append(normalized)
        directories.removeValue(forKey: normalized)
    }
}

private actor RecordingRenamingDirectoryStore: MangaDirectoryPersisting, MangaDirectoryRenaming {
    private var directories: [String: MangaDirectory]
    private(set) var savedDirectories: [MangaDirectory] = []
    private(set) var deletedNames: [String] = []
    private(set) var renameRequests: [(oldName: String, newName: String)] = []

    init(directories: [MangaDirectory] = []) {
        self.directories = Dictionary(uniqueKeysWithValues: directories.map { ($0.cleanBookName, $0) })
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories[name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.values.first { directory in
            directory.chapters.contains { $0.tid == tid.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        savedDirectories.append(directory)
        directories[directory.cleanBookName] = directory
    }

    func deleteDirectory(named name: String) async throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deletedNames.append(normalized)
        directories.removeValue(forKey: normalized)
    }

    func renameDirectory(from oldName: String, to newDirectory: MangaDirectory) async throws {
        let normalized = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameRequests.append((oldName: normalized, newName: newDirectory.cleanBookName))
        directories.removeValue(forKey: normalized)
        directories[newDirectory.cleanBookName] = newDirectory
    }
}

private func makeSeed(tid: String, tagIDs: [String] = []) -> MangaDirectorySeed {
    MangaDirectorySeed(
        currentChapter: makeChapter(tid: tid, title: "第1话", chapterNumber: 1),
        tagIDs: tagIDs,
        cleanBookName: "测试漫画"
    )
}

private func makeDirectory(
    name: String,
    strategy: MangaDirectoryStrategy,
    sourceKey: String,
    tids: [String]
) -> MangaDirectory {
    makeDirectory(
        name: name,
        strategy: strategy,
        sourceKey: sourceKey,
        chapters: tids.map { makeChapter(tid: $0, title: "第\($0)话", chapterNumber: Double($0) ?? 0) }
    )
}

private func makeDirectory(
    name: String,
    strategy: MangaDirectoryStrategy,
    sourceKey: String,
    chapters: [MangaChapter],
    searchKeyword: String? = nil
) -> MangaDirectory {
    MangaDirectory(
        cleanBookName: name,
        strategy: strategy,
        sourceKey: sourceKey,
        chapters: chapters,
        searchKeyword: searchKeyword
    )
}

private func makeChapter(
    tid: String,
    title: String,
    chapterNumber: Double? = nil
) -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: title,
        chapterNumber: chapterNumber ?? MangaTitleCleaner.extractChapterNumber(title)
    )
}

private func makeDocument(tid: String) throws -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        ownerPostID: "post-\(tid)",
        chapterTitle: "第1话",
        imageURLs: [
            try #require(URL(string: "https://img.example.com/\(tid)-0.jpg"))
        ]
    )
}

private func makeContext(tid: String, directoryName: String? = nil) throws -> MangaLaunchContext {
    MangaLaunchContext(
        originalThreadID: tid,
        chapterTID: tid,
        displayTitle: "测试漫画",
        source: .forum,
        directoryName: directoryName
    )
}
