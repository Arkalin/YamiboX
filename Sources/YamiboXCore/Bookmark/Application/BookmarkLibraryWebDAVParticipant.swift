import CryptoKit
import Foundation

/// WebDAV sync participant for the Bookmark Library.
///
/// Bookmarks carry no editable field, so the only transition a row ever makes
/// is "exists" -> "deleted"; newest-record-wins-by-id plus a tombstone set is
/// therefore exact rather than merely adequate here (unlike the Like Library,
/// where colours and notes make rows genuinely mutable). Nothing but
/// `BookmarkItem` metadata travels — a bookmark has no bytes.
struct BookmarkLibraryWebDAVParticipant: MangaIdentitySyncParticipant {
    var mangaIdentityStrategy: MangaIdentityPayloadStrategy? {
        MangaIdentityPayloadStrategy(normalizePayload: BookmarkLibraryWebDAVPayload.normalizingMangaIdentities)
    }

    let datasetID = "bookmarkLibrary"
    let remoteFileName = "yamibox-bookmark-library-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: BookmarkStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: BookmarkStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(BookmarkLibraryWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, revision: payload.syncRevision)
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> WebDAVExportSnapshot {
        let remote = try remoteData.map { try decoder.decode(BookmarkLibraryWebDAVPayload.self, from: $0) }
        let payload = try await merge(remote: remote, at: updatedAt)
        return WebDAVExportSnapshot(data: try encoder.encode(payload), fingerprint: try payload.contentFingerprint())
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let payload = try decoder.decode(BookmarkLibraryWebDAVPayload.self, from: data)
        let merged = try await merge(remote: payload, at: payload.updatedAt)
        let fingerprint = try merged.contentFingerprint()
        return WebDAVApplySnapshot(fingerprint: fingerprint, requiresUpload: fingerprint != (try payload.contentFingerprint()))
    }

    private func merge(remote: BookmarkLibraryWebDAVPayload?, at date: Date) async throws -> BookmarkLibraryWebDAVPayload {
        try await store.updateSyncSnapshot { snapshot in
            let outcome = BookmarkLibraryWebDAVMerger().merge(localSnapshot: snapshot.records,
                remote: remote, updatedAt: date, localTombstones: snapshot.deletions.tombstones)
            snapshot.records = outcome.storageSnapshot
            snapshot.deletions.tombstones = outcome.payload.tombstones
            return outcome.payload
        }
    }

    func readLocalFingerprint() async throws -> String? {
        let snapshot = try await store.syncSnapshot()
        return try BookmarkLibraryWebDAVPayload(updatedAt: .distantPast,
            items: snapshot.records.filter { $0.deletedAt == nil },
            tombstones: snapshot.deletions.tombstones).contentFingerprint()
    }
}

struct BookmarkLibraryWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed (decode falls back to `updatedAt` comparisons then).
    var syncRevision: UInt64?
    var items: [BookmarkItem]
    /// itemID -> deletedAt. Bare by design: a deleted bookmark has nothing left
    /// worth syncing, only the fact and time of deletion.
    var tombstones: [String: Date]

    init(
        version: Int = Self.currentVersion,
        updatedAt: Date,
        syncRevision: UInt64? = nil,
        items: [BookmarkItem],
        tombstones: [String: Date]
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.items = items
        self.tombstones = tombstones
    }

    /// Builds the export payload from the full local snapshot (including
    /// soft-deleted rows): live items are exported with their data,
    /// soft-deleted rows are reduced to a bare tombstone.
    init(updatedAt: Date, localSnapshot: [BookmarkItem]) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.syncRevision = nil
        self.items = localSnapshot.filter { $0.deletedAt == nil }
        self.tombstones = Dictionary(uniqueKeysWithValues: localSnapshot.compactMap { item in
            item.deletedAt.map { (item.id, $0) }
        })
    }

    init(from decoder: any Decoder) throws {
        let fields = try WebDAVItemPayloadFields<BookmarkItem>(from: decoder, currentVersion: Self.currentVersion)
        self.init(version: fields.version, updatedAt: fields.updatedAt,
            syncRevision: fields.syncRevision, items: fields.items, tombstones: fields.tombstones)
    }

    func encode(to encoder: any Encoder) throws {
        try WebDAVItemPayloadFields(version: version, updatedAt: updatedAt,
            syncRevision: syncRevision, items: items, tombstones: tombstones).encode(to: encoder)
    }

    func contentFingerprint() throws -> String {
        try WebDAVSyncFingerprint.make(SyncRecordSnapshot(records: items.sorted { $0.id < $1.id },
            deletions: SyncDeletionState(tombstones: tombstones)))
    }
}

struct BookmarkLibraryWebDAVMerger: Sendable {
    struct MergeOutcome: Sendable {
        var storageSnapshot: [BookmarkItem]
        var payload: BookmarkLibraryWebDAVPayload
    }

    init() {}

    func merge(
        localSnapshot: [BookmarkItem],
        remote: BookmarkLibraryWebDAVPayload?,
        updatedAt: Date,
        localTombstones: [String: Date] = [:]
    ) -> MergeOutcome {
        var byID = Dictionary(localSnapshot.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        for remoteItem in remote?.items ?? [] {
            if let existing = byID[remoteItem.id], existing.updatedAt >= remoteItem.updatedAt {
                continue
            }
            byID[remoteItem.id] = remoteItem
        }

        let rowTombstones = SyncSoftDeletionRules.tombstones(in: localSnapshot, id: \.id, deletedAt: \.deletedAt)
        let mergedTombstones = SyncDeletionState.mergingTombstones(SyncDeletionState.mergingTombstones(localTombstones, rowTombstones), remote?.tombstones ?? [:])

        // Bare tombstones are persisted separately from the optional content.
        let storageSnapshot = SyncSoftDeletionRules.applying(
            mergedTombstones, to: byID.values, id: \.id, updatedAt: \.updatedAt, deletedAt: \.deletedAt
        )

        let deduped = collapsingDuplicatePlaces(in: storageSnapshot, at: updatedAt)
        let payload = BookmarkLibraryWebDAVPayload(
            updatedAt: updatedAt,
            items: deduped.filter { $0.deletedAt == nil },
            tombstones: SyncDeletionState.mergingTombstones(
                mergedTombstones,
                Dictionary(uniqueKeysWithValues: deduped.compactMap { item in
                    item.deletedAt.map { (item.id, $0) }
                })
            )
        )
        return MergeOutcome(storageSnapshot: deduped, payload: payload)
    }

    /// A bookmark's invariant is "one per place", but two devices bookmarking
    /// the same position independently mint two different ids, and an id-keyed
    /// merge keeps both forever. `toggle` then removes only one of them and the
    /// button flips straight back to bookmarked, so the duplicate has to die
    /// here, where it is born.
    ///
    /// The survivor is the earliest-created row, which every device agrees on
    /// without coordinating; ties break on id so the choice is deterministic.
    private func collapsingDuplicatePlaces(in items: [BookmarkItem], at date: Date) -> [BookmarkItem] {
        var survivorsByWork: [ReadingWorkKey: [BookmarkItem]] = [:]
        var result: [BookmarkItem] = []

        for item in items.sorted(by: { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }) {
            guard item.deletedAt == nil else {
                result.append(item)
                continue
            }
            let survivors = survivorsByWork[item.workKey] ?? []
            if survivors.contains(where: { $0.anchor.marksSamePlace(as: item.anchor) }) {
                var collapsed = item
                collapsed.deletedAt = date
                collapsed.updatedAt = max(item.updatedAt, date)
                result.append(collapsed)
                continue
            }
            survivorsByWork[item.workKey, default: []].append(item)
            result.append(item)
        }
        return result
    }

}

private extension BookmarkLibraryWebDAVPayload {
    static func normalizingMangaIdentities(_ data: Data, _ identities: MangaDirectoryIdentitySnapshot, _: [Int: MangaIdentityLegacyTarget]) throws -> Data {
        var payload = try JSONDecoder().decode(Self.self, from: data)
        for index in payload.items.indices {
            payload.items[index].workKey = ReadingWorkIdentityRemapping.normalize(
                payload.items[index].workKey, identities: identities, legacy: false)
        }
        payload.tombstones = MangaIdentityDeletionRemapping.normalize(
            SyncDeletionState(tombstones: payload.tombstones), identities: identities).tombstones
        return try JSONEncoder().encode(payload)
    }
}
