import CryptoKit
import Foundation

/// WebDAV sync participant for the Like Library. Like Items are effectively
/// immutable once created (only "exists" -> "deleted" transitions happen), so
/// this uses newest-record-wins-by-id merge semantics, same as
/// `ReadingProgressWebDAVParticipant`, plus a tombstone set so a stale remote
/// snapshot can't resurrect a locally deleted item. Image bytes never travel
/// in this payload (ADR-0049): only `LikeItem` metadata, which already has no
/// local-file field to strip (`LikeImageStore` resolves bytes purely by
/// `LikeItem.id`, so other devices re-fetch via `sourceImageURL` through the
/// existing `LikeWorkItemsView` fallback, no new code needed here).
struct LikeLibraryWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = "likeLibrary"
    let remoteFileName = "yamibox-like-library-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: LikeStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: LikeStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(LikeLibraryWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, revision: payload.syncRevision)
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> WebDAVExportSnapshot {
        let remote = try remoteData.map { try decoder.decode(LikeLibraryWebDAVPayload.self, from: $0) }
        let payload = try await merge(remote: remote, at: updatedAt)
        return WebDAVExportSnapshot(data: try encoder.encode(payload), fingerprint: try payload.contentFingerprint())
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let payload = try decoder.decode(LikeLibraryWebDAVPayload.self, from: data)
        let merged = try await merge(remote: payload, at: payload.updatedAt)
        let fingerprint = try merged.contentFingerprint()
        return WebDAVApplySnapshot(fingerprint: fingerprint, requiresUpload: fingerprint != (try payload.contentFingerprint()))
    }

    private func merge(remote: LikeLibraryWebDAVPayload?, at date: Date) async throws -> LikeLibraryWebDAVPayload {
        try await store.updateSyncSnapshot { snapshot in
            let outcome = LikeLibraryWebDAVMerger().merge(localSnapshot: snapshot.records,
                remote: remote, updatedAt: date, localTombstones: snapshot.deletions.tombstones)
            snapshot.records = outcome.storageSnapshot
            snapshot.deletions.tombstones = outcome.payload.tombstones
            return outcome.payload
        }
    }

    /// Restores style and notes only for equal versions, preserving genuine edits.
    /// Chapter titles are metadata: a missing snapshot can be filled at any version.
    static func restoringDroppedFields(_ remoteItem: LikeItem, from localByID: [String: LikeItem]) -> LikeItem {
        guard let local = localByID[remoteItem.id] else {
            return remoteItem
        }
        var restored = remoteItem.fillingChapterTitle(from: local)
        guard local.updatedAt == remoteItem.updatedAt else { return restored }
        if restored.style == .default {
            restored.style = local.style
        }
        if restored.note == nil {
            restored.note = local.note
        }
        return restored
    }

    func readLocalFingerprint() async throws -> String? {
        let snapshot = try await store.syncSnapshot()
        return try LikeLibraryWebDAVPayload(updatedAt: .distantPast,
            items: snapshot.records.filter { $0.deletedAt == nil },
            tombstones: snapshot.deletions.tombstones).contentFingerprint()
    }
}

struct LikeLibraryWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed (decode falls back to `updatedAt` comparisons then).
    var syncRevision: UInt64?
    var items: [LikeItem]
    /// itemID -> deletedAt. Bare by design: deleted content has nothing left
    /// worth syncing, only the fact and time of deletion.
    var tombstones: [String: Date]

    init(version: Int = Self.currentVersion, updatedAt: Date, syncRevision: UInt64? = nil, items: [LikeItem], tombstones: [String: Date]) {
        self.version = version
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.items = items
        self.tombstones = tombstones
    }

    /// Builds the export payload from the full local snapshot (including
    /// soft-deleted rows): live items are exported with their data;
    /// soft-deleted rows are reduced to a bare tombstone.
    init(updatedAt: Date, localSnapshot: [LikeItem]) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.syncRevision = nil
        self.items = localSnapshot.filter { $0.deletedAt == nil }
        self.tombstones = Dictionary(uniqueKeysWithValues: localSnapshot.compactMap { item in
            item.deletedAt.map { (item.id, $0) }
        })
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case syncRevision
        case items
        case tombstones
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(Int.self, forKey: .version) else {
            throw WebDAVSyncError.unsupportedPayloadVersion(0)
        }
        guard version == 1 || version == Self.currentVersion else {
            throw WebDAVSyncError.unsupportedPayloadVersion(version)
        }
        self.version = version
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.syncRevision = try container.decodeIfPresent(UInt64.self, forKey: .syncRevision)
        self.items = try container.decode([LikeItem].self, forKey: .items)
        self.tombstones = version == 1
            ? try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
            : try container.decode([String: Date].self, forKey: .tombstones)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(syncRevision, forKey: .syncRevision)
        try container.encode(items, forKey: .items)
        try container.encode(tombstones, forKey: .tombstones)
    }

    func contentFingerprint() throws -> String {
        try WebDAVSyncFingerprint.make(SyncRecordSnapshot(records: items.sorted { $0.id < $1.id },
            deletions: SyncDeletionState(tombstones: tombstones)))
    }
}

struct LikeLibraryWebDAVMerger: Sendable {
    struct MergeOutcome: Sendable {
        var storageSnapshot: [LikeItem]
        var payload: LikeLibraryWebDAVPayload
    }

    init() {}

    func merge(localSnapshot: [LikeItem], remote: LikeLibraryWebDAVPayload?, updatedAt: Date, localTombstones: [String: Date] = [:]) -> MergeOutcome {
        var byID = Dictionary(localSnapshot.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        for remoteItem in remote?.items ?? [] {
            // `>=`, not `>`, is what protects fields a client too old to know
            // about them would flatten (style, note): re-exporting an item does
            // not touch its `updatedAt`, so a payload rewritten by an old client
            // comes back with equal timestamps and loses to the local row.
            //
            // This guard covers the merge path only. The download path
            // (`applyRemote`) needs its own protection and has it — see
            // `restoringDroppedFields`. A device with no local copy at all (a
            // fresh install pulling an already-flattened remote) still cannot
            // recover them, which is the accepted cost of keeping the payload at
            // v1 so old clients keep syncing.
            if let existing = byID[remoteItem.id], existing.updatedAt >= remoteItem.updatedAt {
                byID[remoteItem.id] = existing.fillingChapterTitle(from: remoteItem)
                continue
            }
            byID[remoteItem.id] = byID[remoteItem.id].map { remoteItem.fillingChapterTitle(from: $0) } ?? remoteItem
        }

        let rowTombstones = Dictionary(localSnapshot.compactMap { item in
            item.deletedAt.map { (item.id, $0) }
        }, uniquingKeysWith: max)
        let mergedTombstones = maxDateDictionary(maxDateDictionary(localTombstones, rowTombstones), remote?.tombstones ?? [:])

        // Bare tombstones are persisted separately from the optional content.
        let storageSnapshot: [LikeItem] = byID.values.map { item in
            var resolved = item
            if let deletedAt = mergedTombstones[item.id], deletedAt >= item.updatedAt {
                resolved.deletedAt = deletedAt
                resolved.updatedAt = max(item.updatedAt, deletedAt)
            } else {
                resolved.deletedAt = nil
            }
            return resolved
        }

        let payload = LikeLibraryWebDAVPayload(
            updatedAt: updatedAt,
            items: storageSnapshot.filter { $0.deletedAt == nil },
            tombstones: mergedTombstones
        )
        return MergeOutcome(storageSnapshot: storageSnapshot, payload: payload)
    }
}

private func maxDateDictionary(_ lhs: [String: Date], _ rhs: [String: Date]) -> [String: Date] {
    var result = lhs
    for (key, value) in rhs {
        if let existing = result[key], existing >= value {
            continue
        }
        result[key] = value
    }
    return result
}
