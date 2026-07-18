import Foundation
@preconcurrency import GRDB

extension OfflineCacheStore {
    func offlineCacheManagementSnapshot() async -> OfflineCacheManagementSnapshot {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                try Self.managementSnapshot(
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                )
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to build offline cache management snapshot: \(error)")
            return OfflineCacheManagementSnapshot(groups: [])
        }
    }

    private static func managementSnapshot(
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> OfflineCacheManagementSnapshot {
        var builders: [OfflineCacheEntryID: OfflineCacheManagementEntryBuilder] = [:]
        var groupTitles: [OfflineCacheGroupID: OfflineCacheManagementGroupTitle] = [:]

        for membership in try allMangaMemberships(
            fileManager: fileManager,
            mangaSourcePagesDirectory: mangaSourcePagesDirectory,
            sourcePageCache: sourcePageCache,
            in: db
        ) {
            let entryID = OfflineCacheEntryID(
                readerKind: .manga,
                ownerKey: membership.ownerName,
                entryKey: membership.tid
            )
            var builder = builders[entryID] ?? OfflineCacheManagementEntryBuilder(
                id: entryID,
                title: offlineCacheEntryTitle(chapterTitle: membership.chapterTitle, entryKey: membership.tid),
                state: .cached,
                updatedAt: membership.createdAt
            )
            builder.title = offlineCacheEntryTitle(chapterTitle: membership.chapterTitle, entryKey: membership.tid)
            builder.byteCount += try mangaEntryByteCount(ownerName: membership.ownerName, tid: membership.tid, in: db)
            builder.imageURLStrings.formUnion(membership.imageURLs.map(\.absoluteString))
            builder.updatedAt = max(builder.updatedAt, membership.createdAt)
            builders[entryID] = builder
            recordGroupTitle(membership.ownerName, updatedAt: membership.createdAt, groupID: entryID.groupID, in: &groupTitles)
        }

        for entry in try allNovelEntries(in: db) {
            let entryID = entry.id
            var builder = builders[entryID] ?? OfflineCacheManagementEntryBuilder(
                id: entryID,
                title: entry.title,
                state: .cached,
                updatedAt: entry.updatedAt
            )
            builder.title = entry.title
            builder.byteCount += try novelEntryByteCount(entryKey: entryID.entryKey, in: db)
            builder.imageURLStrings.formUnion(entry.imageURLs.map(\.absoluteString))
            builder.updatedAt = max(builder.updatedAt, entry.updatedAt)
            builders[entryID] = builder
            recordGroupTitle(entry.ownerTitle, updatedAt: entry.updatedAt, groupID: entryID.groupID, in: &groupTitles)
        }

        for work in try allRawWorks(in: db) {
            let entryID = OfflineCacheEntryID(
                readerKind: work.readerKind,
                ownerKey: work.ownerKey,
                entryKey: work.entryKey
            )
            var builder = builders[entryID] ?? OfflineCacheManagementEntryBuilder(
                id: entryID,
                title: offlineCacheEntryTitle(chapterTitle: work.title, entryKey: work.entryKey),
                state: .queued,
                updatedAt: work.updatedAt
            )
            builder.title = offlineCacheEntryTitle(chapterTitle: work.title, entryKey: work.entryKey)
            builder.state = OfflineCacheEntryState(workState: work.state)
            builder.updatedAt = max(builder.updatedAt, work.updatedAt)
            builder.workID = OfflineCacheWorkID(readerKind: work.readerKind, rawValue: work.workID)
            builder.imageURLStrings.formUnion((work.targetImageURLs + work.completedImageURLs).map(\.absoluteString))
            builders[entryID] = builder
            recordGroupTitle(work.ownerTitle, updatedAt: work.updatedAt, groupID: entryID.groupID, in: &groupTitles)
        }

        let entries = try builders.values.map { builder in
            try builder.entry(byteCount: builder.byteCount + imageAssetByteCount(forImageURLStrings: builder.imageURLStrings, in: db))
        }
        let grouped = Dictionary(grouping: entries, by: \.id.groupID)
        let groups = try grouped.map { groupID, entries in
            let sortedEntries = entries.sorted { lhs, rhs in
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return lhs.id.entryKey.localizedStandardCompare(rhs.id.entryKey) == .orderedAscending
            }
            let groupURLStrings = builders.values
                .filter { $0.id.groupID == groupID }
                .reduce(into: Set<String>()) { $0.formUnion($1.imageURLStrings) }
            let groupEntryBytes = builders.values
                .filter { $0.id.groupID == groupID }
                .reduce(0) { $0 + $1.byteCount }
            let byteCount = try groupEntryBytes + imageAssetByteCount(forImageURLStrings: groupURLStrings, in: db)
            let pendingCount = sortedEntries.filter { [.queued, .running, .paused].contains($0.state) }.count
            let failedCount = sortedEntries.filter { $0.state == .failed }.count
            let cachedCount = sortedEntries.filter { $0.state == .cached }.count
            return OfflineCacheManagementGroup(
                id: groupID,
                title: groupTitles[groupID]?.title ?? groupID.ownerKey,
                byteCount: byteCount,
                cachedCount: cachedCount,
                pendingCount: pendingCount,
                failedCount: failedCount,
                updatedAt: sortedEntries.map(\.updatedAt).max() ?? Date(timeIntervalSince1970: 0),
                entries: sortedEntries
            )
        }
        .sorted { lhs, rhs in
            if lhs.id.readerKind != rhs.id.readerKind {
                return lhs.id.readerKind.rawValue < rhs.id.readerKind.rawValue
            }
            let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return lhs.id.ownerKey.localizedStandardCompare(rhs.id.ownerKey) == .orderedAscending
        }

        return OfflineCacheManagementSnapshot(groups: groups)
    }

    private static func recordGroupTitle(
        _ title: String,
        updatedAt: Date,
        groupID: OfflineCacheGroupID,
        in groupTitles: inout [OfflineCacheGroupID: OfflineCacheManagementGroupTitle]
    ) {
        guard let title = title.mangaReaderTrimmedNonEmpty else { return }
        if let existing = groupTitles[groupID], existing.updatedAt > updatedAt {
            return
        }
        groupTitles[groupID] = OfflineCacheManagementGroupTitle(title: title, updatedAt: updatedAt)
    }

}

private struct OfflineCacheManagementGroupTitle {
    var title: String
    var updatedAt: Date
}

private struct OfflineCacheManagementEntryBuilder {
    var id: OfflineCacheEntryID
    var title: String
    var imageURLStrings: Set<String> = []
    var byteCount = 0
    var state: OfflineCacheEntryState
    var updatedAt: Date
    var workID: OfflineCacheWorkID?

    func entry(byteCount: Int) -> OfflineCacheManagementEntry {
        OfflineCacheManagementEntry(
            id: id,
            title: title,
            byteCount: byteCount,
            state: state,
            updatedAt: updatedAt,
            workID: workID
        )
    }
}
