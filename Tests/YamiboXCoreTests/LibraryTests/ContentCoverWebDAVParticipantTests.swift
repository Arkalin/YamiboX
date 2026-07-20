import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func contentCoverWebDAVParticipantExportsLocalCoversWhenNoRemote() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-export"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let coverURL = try #require(URL(string: "https://img.example.com/cover.jpg"))
    _ = try await store.setAutomaticCover(coverURL, for: .thread(tid: "100"))

    let data = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "acct")
    let payload = try JSONDecoder().decode(ContentCoverWebDAVPayload.self, from: data)

    #expect(payload.covers.count == 1)
    #expect(payload.covers.first?.key == .thread(tid: "100"))
    #expect(payload.covers.first?.automaticCoverURL == coverURL)
}

@Test func contentCoverWebDAVParticipantAppliesRemoteCoversLocally() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-apply"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let threadURL = try #require(URL(string: "https://img.example.com/thread.jpg"))
    let mangaURL = try #require(URL(string: "https://img.example.com/manga.jpg"))
    let remotePayload = ContentCoverWebDAVPayload(
        updatedAt: .now,
        covers: [
            ContentCover(key: .thread(tid: "200"), automaticCoverURL: threadURL),
            ContentCover(
                key: .smartManga(cleanBookName: "测试漫画"),
                manualCoverURL: mangaURL,
                dynamicEnabled: false
            ),
        ]
    )

    try await participant.applyRemote(try JSONEncoder().encode(remotePayload))

    // The favorites grid resolves covers through this exact read path, so the
    // WebDAV-arrived favorite now renders its cover instead of the text
    // placeholder — the original bug this participant exists to fix.
    let threadCover = await store.cover(for: .thread(tid: "200"))
    #expect(threadCover?.resolvedURL == threadURL)
    let mangaCover = await store.cover(for: .smartManga(cleanBookName: "测试漫画"))
    #expect(mangaCover?.resolvedURL == mangaURL)
    #expect(mangaCover?.dynamicEnabled == false)
}

@Test func contentCoverWebDAVParticipantMergesByNewestRowAndUnionsDistinctKeys() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-merge"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let localOldURL = try #require(URL(string: "https://img.example.com/local-old.jpg"))
    let localNewURL = try #require(URL(string: "https://img.example.com/local-new.jpg"))
    let remoteNewURL = try #require(URL(string: "https://img.example.com/remote-new.jpg"))
    let remoteOldURL = try #require(URL(string: "https://img.example.com/remote-old.jpg"))
    let remoteOnlyURL = try #require(URL(string: "https://img.example.com/remote-only.jpg"))

    // shared-1: local older, remote newer -> remote wins.
    // shared-2: local newer, remote older -> local survives.
    // local-only / remote-only: both survive the union.
    _ = try await store.setAutomaticCover(localOldURL, for: .thread(tid: "shared-1"), date: older)
    _ = try await store.setAutomaticCover(localNewURL, for: .thread(tid: "shared-2"), date: newer)
    _ = try await store.setAutomaticCover(localNewURL, for: .thread(tid: "local-only"), date: older)
    let remotePayload = ContentCoverWebDAVPayload(
        updatedAt: newer,
        covers: [
            ContentCover(key: .thread(tid: "shared-1"), manualCoverURL: remoteNewURL, dynamicEnabled: false, updatedAt: newer),
            ContentCover(key: .thread(tid: "shared-2"), automaticCoverURL: remoteOldURL, updatedAt: older),
            ContentCover(key: .thread(tid: "remote-only"), automaticCoverURL: remoteOnlyURL, updatedAt: older),
        ]
    )

    let data = try await participant.mergeAndExport(
        remoteData: try JSONEncoder().encode(remotePayload),
        updatedAt: .now,
        accountUID: "acct"
    )
    let merged = try JSONDecoder().decode(ContentCoverWebDAVPayload.self, from: data)

    #expect(merged.covers.count == 4)
    let byTID = Dictionary(uniqueKeysWithValues: merged.covers.map { ($0.key.targetID, $0) })
    #expect(byTID["shared-1"]?.manualCoverURL == remoteNewURL)
    #expect(byTID["shared-1"]?.dynamicEnabled == false)
    #expect(byTID["shared-2"]?.automaticCoverURL == localNewURL)
    #expect(byTID["local-only"] != nil)
    #expect(byTID["remote-only"] != nil)

    // The merge result is also what got persisted locally.
    let storedShared1 = await store.cover(for: .thread(tid: "shared-1"))
    #expect(storedShared1?.resolvedURL == remoteNewURL)
    let storedRemoteOnly = await store.cover(for: .thread(tid: "remote-only"))
    #expect(storedRemoteOnly?.resolvedURL == remoteOnlyURL)
}

@Test func contentCoverWebDAVParticipantSyncsForcedTextCoverIntent() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-forced"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let coverURL = try #require(URL(string: "https://img.example.com/cover.jpg"))
    _ = try await store.setAutomaticCover(coverURL, for: .thread(tid: "300"), date: older)

    // The other device toggled "use text cover" after this device stored the
    // automatic URL; the newer row must carry that intent over here.
    let remotePayload = ContentCoverWebDAVPayload(
        updatedAt: newer,
        covers: [
            ContentCover(key: .thread(tid: "300"), automaticCoverURL: coverURL, textCoverForced: true, updatedAt: newer)
        ]
    )
    _ = try await participant.mergeAndExport(
        remoteData: try JSONEncoder().encode(remotePayload),
        updatedAt: .now,
        accountUID: "acct"
    )

    let stored = await store.cover(for: .thread(tid: "300"))
    #expect(stored?.textCoverForced == true)
    #expect(stored?.resolvedURL == nil)
}

@Test func contentCoverWebDAVParticipantRejectsUnsupportedPayloadVersion() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-version"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let futurePayload = Data("""
    {"version": 99, "updatedAt": 0, "covers": []}
    """.utf8)

    #expect(throws: WebDAVSyncError.self) {
        try participant.inspectRemote(futurePayload)
    }
}

@Test func contentCoverWebDAVParticipantToleratesDuplicateKeysFromMalformedPayloads() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-duplicate"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    let oldURL = try #require(URL(string: "https://img.example.com/old.jpg"))
    let newURL = try #require(URL(string: "https://img.example.com/new.jpg"))
    let remotePayload = ContentCoverWebDAVPayload(
        updatedAt: newer,
        covers: [
            ContentCover(key: .thread(tid: "400"), automaticCoverURL: oldURL, updatedAt: older),
            ContentCover(key: .thread(tid: "400"), automaticCoverURL: newURL, updatedAt: newer),
        ]
    )

    let data = try await participant.mergeAndExport(
        remoteData: try JSONEncoder().encode(remotePayload),
        updatedAt: .now,
        accountUID: "acct"
    )
    let merged = try JSONDecoder().decode(ContentCoverWebDAVPayload.self, from: data)

    #expect(merged.covers.count == 1)
    #expect(merged.covers.first?.automaticCoverURL == newURL)
}

@Test func contentCoverWebDAVParticipantFingerprintIsStableAcrossReloadsAndChangesOnWrite() async throws {
    let store = ContentCoverStore(databasePool: try makeContentCoverWebDAVTestDatabasePool(prefix: "cover-webdav-fingerprint"))
    let participant = ContentCoverWebDAVParticipant(store: store)
    let coverURL = try #require(URL(string: "https://img.example.com/cover.jpg"))
    let otherURL = try #require(URL(string: "https://img.example.com/other.jpg"))
    _ = try await store.setAutomaticCover(coverURL, for: .thread(tid: "500"), date: Date(timeIntervalSince1970: 1_000))

    let first = await participant.localFingerprint()
    let second = await participant.localFingerprint()
    #expect(first != nil)
    #expect(first == second)

    _ = try await store.setManualCover(otherURL, for: .thread(tid: "500"), date: Date(timeIntervalSince1970: 2_000))
    let afterWrite = await participant.localFingerprint()
    #expect(afterWrite != first)
}

private func makeContentCoverWebDAVTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}
