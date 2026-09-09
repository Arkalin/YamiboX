import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func favoriteDeletionStopsOnRemoteFailureWithoutLocalChanges() async throws {
    let items = try [deletionItem("1"), deletionItem("2"), deletionItem("3")]
    let fixture = try await DeletionFixture(items)
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let before = try await store.load()
    let remote = DeletionRemote(failingID: "remote-2")
    await #expect(throws: DeletionFailure.self) {
        try await FavoriteCommands.deleteFavorites(
            FavoriteDeletionRequest(favoriteIDs: Set(items.map(\.id)), scope: .everywhere(removeRemote: true)),
            localFavoriteLibraryStore: store, makeRemoteRepository: { remote }
        )
    }
    #expect(await remote.deletedIDs == ["remote-1", "remote-2"])
    #expect(try await store.load() == before)
}

@Test func favoriteDeletionSkipsParsingFailuresAndMissingRemoteIDs() async throws {
    let items = try [deletionItem("1", remoteID: "  "), deletionItem("2"), deletionItem("3", remoteID: ""), deletionItem("4")]
    let fixture = try await DeletionFixture(items)
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let remote = DeletionRemote(parsingID: "remote-2", parsingThreadID: "1")
    let result = try await FavoriteCommands.deleteFavorites(
        FavoriteDeletionRequest(favoriteIDs: Set(items.map(\.id)), scope: .everywhere(removeRemote: true)),
        localFavoriteLibraryStore: store, makeRemoteRepository: { remote }
    )
    #expect(result.items.isEmpty)
    #expect(await remote.deletedIDs == ["remote-2", "remote-4"])
    #expect(await remote.lookups == ["1", "3"])
}

@Test func favoriteDeletionPreservesConcurrentUnrelatedEdits() async throws {
    let selected = try deletionItem("1")
    let unrelated = try deletionItem("2")
    let added = try deletionItem("3")
    let fixture = try await DeletionFixture([selected, unrelated])
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let gate = DeletionGate()
    let remote = DeletionRemote(gate: gate)
    let deletion = Task {
        try await FavoriteCommands.deleteFavorite(
            id: selected.id, scope: .everywhere(removeRemote: true),
            localFavoriteLibraryStore: store, makeRemoteRepository: { remote }
        )
    }
    await gate.waitForArrival()
    try await store.update { document in
        document.upsertItem(added)
        let index = document.items.firstIndex(where: { $0.id == unrelated.id })!
        document.items[index].displayName = "Concurrent edit"
    }
    await gate.release()
    let result = try #require(try await deletion.value)
    #expect(Set(result.items.map(\.id)) == [unrelated.id, added.id])
    #expect(result.items.first(where: { $0.id == unrelated.id })?.displayName == "Concurrent edit")
    #expect(try await store.load() == result)
}

@Test func favoriteDeletionCancellationAfterRemoteWaitPreservesLocalItems() async throws {
    let item = try deletionItem("1")
    let fixture = try await DeletionFixture([item])
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let before = try await store.load()
    let gate = DeletionGate()
    let remote = DeletionRemote(gate: gate)
    let deletion = Task {
        try await FavoriteCommands.deleteFavorite(
            id: item.id, scope: .everywhere(removeRemote: true),
            localFavoriteLibraryStore: store, makeRemoteRepository: { remote }
        )
    }
    await gate.waitForArrival()
    deletion.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await deletion.value }
    #expect(try await store.load() == before)
}

@Test func favoriteDeletionMissingSingleItemDoesNotWriteOrCreateRemote() async throws {
    let fixture = try await DeletionFixture([])
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    try await fixture.database.write { db in
        try db.execute(sql: "CREATE TRIGGER reject_insert BEFORE INSERT ON favorite_library_document BEGIN SELECT RAISE(ABORT, 'unexpected write'); END")
    }
    let result = try await FavoriteCommands.deleteFavorite(
        id: "absent", scope: .everywhere(removeRemote: true),
        localFavoriteLibraryStore: store,
        makeRemoteRepository: {
            Issue.record("An absent item must not create a remote repository")
            return DeletionRemote()
        }
    )
    #expect(result == nil)
    #expect(await store.hasStoredDocument() == false)
}

@Test func favoriteDeletionLocalSaveFailureRollsBackWholeBatch() async throws {
    let items = try [deletionItem("1"), deletionItem("2")]
    let fixture = try await DeletionFixture(items)
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let before = try await store.load()
    try await fixture.database.write { db in
        try db.execute(sql: "CREATE TRIGGER reject_update BEFORE UPDATE ON favorite_library_document BEGIN SELECT RAISE(ABORT, 'save failure'); END")
    }
    await #expect(throws: YamiboPersistenceError.self) {
        try await FavoriteCommands.deleteFavorites(
            FavoriteDeletionRequest(favoriteIDs: Set(items.map(\.id)), scope: .everywhere(removeRemote: false)),
            localFavoriteLibraryStore: store, makeRemoteRepository: { DeletionRemote() }
        )
    }
    #expect(try await store.load() == before)
}

@Test func favoriteDeletionCurrentLocationRetainsLastLocationAndAvoidsRemote() async throws {
    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "Second")
    let single = try deletionItem("1")
    var multiple = try deletionItem("2")
    multiple.locations.append(.category(category.id))
    document.upsertItem(single)
    document.upsertItem(multiple)
    let fixture = try await DeletionFixture([])
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    try await store.save(document)
    let result = try await FavoriteCommands.deleteFavorites(
        FavoriteDeletionRequest(favoriteIDs: [single.id, multiple.id], scope: .currentLocation(.category(FavoriteCategory.defaultID))),
        localFavoriteLibraryStore: store,
        makeRemoteRepository: {
            Issue.record("Location removal must not create a remote repository")
            return DeletionRemote()
        }
    )
    #expect(result.items.first(where: { $0.id == single.id })?.locations == single.locations)
    #expect(result.items.first(where: { $0.id == multiple.id })?.locations == [.category(category.id)])
}

@Test func favoriteDeletionBatchUsesFixedSnapshotAndDissolvesWithoutDeletingUnselectedMembers() async throws {
    let selected = try deletionItem("1")
    var document = FavoriteLibraryDocument(items: [selected])
    let collection = document.createCollection(categoryID: FavoriteCategory.defaultID, name: "Collection")
    var member = try deletionItem("2")
    member.locations = [.collection(categoryID: FavoriteCategory.defaultID, collectionID: collection.id)]
    document.upsertItem(member)
    let addedDuringWait = try deletionItem("3")
    let fixture = try await DeletionFixture([])
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    try await store.save(document)
    let gate = DeletionGate()
    let remote = DeletionRemote(gate: gate)
    let request = FavoriteDeletionRequest(
        favoriteIDs: [selected.id, addedDuringWait.id], collectionIDs: [collection.id],
        scope: .everywhere(removeRemote: true)
    )
    let deletion = Task {
        try await FavoriteCommands.deleteFavorites(
            request, localFavoriteLibraryStore: store, makeRemoteRepository: { remote }
        )
    }
    await gate.waitForArrival()
    try await store.update { latest in latest.upsertItem(addedDuringWait) }
    await gate.release()
    let result = try await deletion.value
    #expect(result.collections.isEmpty)
    #expect(Set(result.items.map(\.id)) == [member.id, addedDuringWait.id])
    #expect(result.items.first(where: { $0.id == member.id })?.locations == [.category(FavoriteCategory.defaultID)])
    #expect(await remote.deletedIDs == ["remote-1"])
    #expect(try await store.load() == result)
}

@Test func favoriteDeletionSingleDisappearingDuringRemoteWaitDoesNotWrite() async throws {
    let item = try deletionItem("1")
    let fixture = try await DeletionFixture([item])
    defer { withExtendedLifetime(fixture) {} }
    let store = fixture.store
    let gate = DeletionGate()
    let remote = DeletionRemote(gate: gate)
    let deletion = Task {
        try await FavoriteCommands.deleteFavorite(
            id: item.id, scope: .everywhere(removeRemote: true),
            localFavoriteLibraryStore: store, makeRemoteRepository: { remote }
        )
    }
    await gate.waitForArrival()
    try await store.update { document in document.removeItem(target: item.target) }
    let before = try await store.load()
    try await fixture.database.write { db in
        try db.execute(sql: "CREATE TRIGGER reject_update BEFORE UPDATE ON favorite_library_document BEGIN SELECT RAISE(ABORT, 'unexpected write'); END")
    }
    await gate.release()
    #expect(try await deletion.value == nil)
    #expect(try await store.load() == before)
}

private func deletionItem(_ id: String, remoteID: String? = nil) throws -> FavoriteItem {
    try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: id), title: id,
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: remoteID ?? "remote-\(id)"),
        locations: [.category(FavoriteCategory.defaultID)]
    )
}

private final class DeletionFixture: Sendable {
    let root: URL
    let database: DatabasePool
    let store: FavoriteLibraryStore

    init(_ items: [FavoriteItem]) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try YamiboDatabase.openPool(rootDirectory: root)
        store = FavoriteLibraryStore(databasePool: database)
        if !items.isEmpty {
            try await store.save(FavoriteLibraryDocument(items: items))
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct DeletionFailure: Error {}

private actor DeletionRemote: ForumThreadFavoriteRemoteOperating {
    let failingID: String?
    let parsingID: String?
    let parsingThreadID: String?
    let gate: DeletionGate?
    var deletedIDs: [String] = []
    var lookups: [String] = []

    init(failingID: String? = nil, parsingID: String? = nil, parsingThreadID: String? = nil, gate: DeletionGate? = nil) {
        self.failingID = failingID
        self.parsingID = parsingID
        self.parsingThreadID = parsingThreadID
        self.gate = gate
    }

    func addThreadFavorite(threadID: String, formHash: String?, resolveRemoteFavorite: Bool) async throws -> Favorite? { nil }

    func deleteFavorite(remoteFavoriteID: String) async throws {
        deletedIDs.append(remoteFavoriteID)
        if let gate { await gate.arriveAndWait() }
        if remoteFavoriteID == failingID { throw DeletionFailure() }
        if remoteFavoriteID == parsingID { throw YamiboError.parsingFailed(context: "test") }
    }

    func remoteFavorite(forThreadID threadID: String, maxPages: Int) async throws -> Favorite? {
        #expect(maxPages == 30)
        lookups.append(threadID)
        if threadID == parsingThreadID { throw YamiboError.parsingFailed(context: "test") }
        return nil
    }
}

private actor DeletionGate {
    private var arrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
