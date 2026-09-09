import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore
import YamiboXTestSupport

final class FavoriteCommandsTests: Sendable {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func rememberedChoicesPersistIndependently() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "favorite-command-settings")
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: try YamiboTestDefaults.make(suiteName: suiteName))
        await FavoriteCommands.rememberAddSyncChoice(true, settingsStore: settingsStore)
        await FavoriteCommands.rememberRemoveRemoteChoice(false, settingsStore: settingsStore)
        let settings = await settingsStore.load().favorites
        #expect(!settings.addSyncPromptEnabled)
        #expect(settings.addSyncDefault)
        #expect(!settings.removeRemotePromptEnabled)
        #expect(!settings.removeRemoteDefault)
    }

    @Test func addPersistsBeforeRemoteAndNormalizesMapping() async throws {
        let store = try makeStore()
        let remote = Remote(add: {
            let document = try await store.load()
            #expect(document.items.count == 1)
            return Favorite(title: "Remote", threadID: "1", remoteFavoriteID: "  42  ")
        })
        let result = try await add(store, remote: remote)
        #expect(result.remote == .synced)
        #expect(result.favorite.remoteFavoriteID == "42")
        #expect(try await store.load().items.first?.remoteMapping?.yamiboFavoriteID == "42")
    }

    @Test func remoteFailureDoesNotUndoLocalAdd() async throws {
        let store = try makeStore()
        let result = try await add(store, remote: Remote(add: { throw Failure() }))
        #expect(result.remote == .failed("remote failure"))
        #expect(result.failureDetails != nil)
        #expect(try await store.load().items.count == 1)
    }

    @Test func mappingWriteFailureDoesNotUndoLocalAdd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try YamiboDatabase.openPool(rootDirectory: root)
        let store = FavoriteLibraryStore(databasePool: pool)
        let remote = Remote(add: {
            try await pool.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_mapping BEFORE UPDATE ON favorite_library_document BEGIN SELECT RAISE(ABORT, 'mapping rejected'); END")
            }
            return Favorite(title: "Remote", threadID: "1", remoteFavoriteID: "42")
        })
        let result = try await add(store, remote: remote)
        guard case .failed = result.remote else {
            Issue.record("Mapping write failure must be reported")
            return
        }
        #expect(result.failureDetails != nil)
        let document = try await store.load()
        #expect(document.items.count == 1)
        #expect(document.items.first?.remoteMapping == nil)
    }

    @Test func cancellationPropagatesAfterLocalAdd() async throws {
        let store = try makeStore()
        await #expect(throws: CancellationError.self) {
            _ = try await add(store, remote: Remote(add: { throw CancellationError() }))
        }
        #expect(try await store.load().items.count == 1)
    }

    @Test func unavailableRemoteStillAddsLocally() async throws {
        let store = try makeStore()
        #expect(try await add(store, remote: nil).remote == .notAttempted)
        #expect(try await store.load().items.count == 1)
    }

    @Test func unresolvedRemoteMappingIsSuccessfulPush() async throws {
        #expect(try await add(makeStore(), remote: Remote()).remote == .syncedWithoutMapping)
    }

    @Test func removeLookupFailurePreservesLocalItem() async throws {
        let store = try makeStore()
        let result = try await add(store, remote: nil)
        let error = YamiboError.parsingFailed(context: "lookup")
        await #expect(throws: error) {
            try await FavoriteCommands.removeFavorite(
                result.favorite, removeRemote: true, boardReaderSettings: BoardReaderSettings(),
                localFavoriteLibraryStore: store, remoteRepository: Remote(lookup: { throw error })
            )
        }
        #expect(try await store.load().items.count == 1)
    }

    @Test func removeUsesStoredTargetAndDeletesRemoteFirst() async throws {
        let store = try makeStore()
        let target = FavoriteItemTarget(kind: .mangaThread, threadID: "1")
        try await store.update { document in
            document.upsertItem(try FavoriteItem(target: target, title: "Manga", locations: [.category(document.defaultCategory.id)]))
        }
        let remote = Remote(delete: { id in
            #expect(id == "42")
            let document = try await store.load()
            #expect(document.items.first?.target == target)
        })
        try await FavoriteCommands.removeFavorite(
            Favorite(title: "Manga", threadID: "1", remoteFavoriteID: " 42 ", type: .other),
            removeRemote: true, boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: store, remoteRepository: remote
        )
        #expect(try await store.load().items.isEmpty)
    }

    @Test func remoteDeleteFailurePreservesLocalItem() async throws {
        let store = try makeStore()
        var favorite = try await add(store, remote: nil).favorite
        favorite.remoteFavoriteID = "42"
        let storedFavorite = favorite
        await #expect(throws: Failure.self) {
            try await FavoriteCommands.removeFavorite(
                storedFavorite, removeRemote: true, boardReaderSettings: BoardReaderSettings(),
                localFavoriteLibraryStore: store, remoteRepository: Remote(delete: { _ in throw Failure() })
            )
        }
        #expect(try await store.load().items.count == 1)
    }

    private func add(_ store: FavoriteLibraryStore, remote: Remote?) async throws -> FavoriteCommands.AddResult {
        try await FavoriteCommands.addFavorite(
            threadID: "1", title: "Favorite", type: .other, authorID: nil, formHash: nil,
            syncToRemote: true, boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: store, remoteRepository: remote
        )
    }

    private func makeStore() throws -> FavoriteLibraryStore {
        let pool = try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent(UUID().uuidString))
        return FavoriteLibraryStore(databasePool: pool)
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "remote failure" }
    }

    private struct Remote: ForumThreadFavoriteRemoteOperating {
        var add: @Sendable () async throws -> Favorite? = { nil }
        var delete: @Sendable (String) async throws -> Void = { _ in }
        var lookup: @Sendable () async throws -> Favorite? = { nil }

        func addThreadFavorite(threadID: String, formHash: String?, resolveRemoteFavorite: Bool) async throws -> Favorite? {
            #expect(threadID == "1")
            #expect(resolveRemoteFavorite)
            return try await add()
        }
        func deleteFavorite(remoteFavoriteID: String) async throws { try await delete(remoteFavoriteID) }
        func remoteFavorite(forThreadID threadID: String, maxPages: Int) async throws -> Favorite? {
            #expect(maxPages == 30)
            return try await lookup()
        }
    }
}
