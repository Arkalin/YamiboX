import Foundation
@preconcurrency import GRDB

extension DownloadStore {
    func downloadManagementSnapshot() async throws -> DownloadManagementSnapshot {
        try await ensureQueueRecovered()
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
            throw downloadPersistenceError(from: error)
        }
    }

    private static func managementSnapshot(
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> DownloadManagementSnapshot {
        var builders: [DownloadEntryID: DownloadManagementEntryBuilder] = [:]
        var groupTitles: [DownloadGroupID: DownloadManagementGroupTitle] = [:]

        for membership in try allMangaMemberships(
            fileManager: fileManager,
            mangaSourcePagesDirectory: mangaSourcePagesDirectory,
            sourcePageCache: sourcePageCache,
            in: db
        ) {
            let entryID = DownloadEntryID(
                readerKind: .manga,
                ownerKey: membership.ownerName,
                entryKey: membership.tid
            )
            var builder = builders[entryID] ?? DownloadManagementEntryBuilder(
                id: entryID,
                title: downloadEntryTitle(chapterTitle: membership.chapterTitle, entryKey: membership.tid),
                state: .downloaded,
                updatedAt: membership.createdAt
            )
            builder.title = downloadEntryTitle(chapterTitle: membership.chapterTitle, entryKey: membership.tid)
            builder.byteCount += try mangaEntryByteCount(ownerName: membership.ownerName, tid: membership.tid, in: db)
            builder.imageURLStrings.formUnion(membership.imageURLs.map(\.absoluteString))
            builder.updatedAt = max(builder.updatedAt, membership.createdAt)
            builders[entryID] = builder
            let ownerTitle = try mangaOwnerTitle(membership.ownerName, in: db)
            recordGroupTitle(ownerTitle, updatedAt: membership.createdAt, groupID: entryID.groupID, in: &groupTitles)
        }

        for entry in try allNovelEntries(in: db) {
            let entryID = entry.id
            var builder = builders[entryID] ?? DownloadManagementEntryBuilder(
                id: entryID,
                title: entry.title,
                state: .downloaded,
                updatedAt: entry.updatedAt
            )
            builder.title = entry.title
            builder.byteCount += try novelEntryByteCount(entryKey: entryID.entryKey, in: db)
            builder.imageURLStrings.formUnion(entry.imageURLs.map(\.absoluteString))
            builder.updatedAt = max(builder.updatedAt, entry.updatedAt)
            builders[entryID] = builder
            recordGroupTitle(entry.ownerTitle, updatedAt: entry.updatedAt, groupID: entryID.groupID, in: &groupTitles)
        }

        for row in try Row.fetchAll(db, sql: "SELECT * FROM download_attachment_entries") {
            let id = DownloadEntryID(readerKind: .attachment, ownerKey: row["owner_name"], entryKey: row["entry_key"])
            let date = Date(timeIntervalSince1970: row["updated_at"])
            builders[id] = DownloadManagementEntryBuilder(id: id, title: row["file_name"], byteCount: row["byte_count"], state: .downloaded, updatedAt: date)
            recordGroupTitle(row["owner_title"], updatedAt: date, groupID: id.groupID, in: &groupTitles)
        }

        for work in try allRawWorks(in: db) {
            let entryID = DownloadEntryID(
                readerKind: work.readerKind,
                ownerKey: work.ownerKey,
                entryKey: work.entryKey
            )
            var builder = builders[entryID] ?? DownloadManagementEntryBuilder(
                id: entryID,
                title: downloadEntryTitle(chapterTitle: work.title, entryKey: work.entryKey),
                state: .queued,
                updatedAt: work.updatedAt
            )
            builder.title = downloadEntryTitle(chapterTitle: work.title, entryKey: work.entryKey)
            builder.state = DownloadEntryState(workState: work.state)
            builder.updatedAt = max(builder.updatedAt, work.updatedAt)
            builder.workID = DownloadWorkID(readerKind: work.readerKind, rawValue: work.workID)
            builder.imageURLStrings.formUnion((work.targetImageURLs + work.completedImageURLs).map(\.absoluteString))
            builders[entryID] = builder
            let ownerTitle = work.readerKind == .manga ? try mangaOwnerTitle(work.ownerKey, fallback: work.ownerTitle, in: db) : work.ownerTitle
            recordGroupTitle(ownerTitle, updatedAt: work.updatedAt, groupID: entryID.groupID, in: &groupTitles)
        }

        var groupURLStrings: [DownloadGroupID: Set<String>] = [:]
        var groupEntryBytes: [DownloadGroupID: Int] = [:]
        let entries = try builders.values.map { builder in
            groupURLStrings[builder.id.groupID, default: []].formUnion(builder.imageURLStrings)
            groupEntryBytes[builder.id.groupID, default: 0] += builder.byteCount
            return try builder.entry(byteCount: builder.byteCount + imageAssetByteCount(forImageURLStrings: builder.imageURLStrings, in: db))
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
            let byteCount = try (groupEntryBytes[groupID] ?? 0)
                + imageAssetByteCount(forImageURLStrings: groupURLStrings[groupID] ?? [], in: db)
            let pendingCount = sortedEntries.filter { [.queued, .running, .paused].contains($0.state) }.count
            let failedCount = sortedEntries.filter { $0.state == .failed }.count
            let downloadedCount = sortedEntries.filter { $0.state == .downloaded }.count
            return DownloadManagementGroup(
                id: groupID,
                title: groupTitles[groupID]?.title ?? groupID.ownerKey,
                byteCount: byteCount,
                downloadedCount: downloadedCount,
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

        return DownloadManagementSnapshot(groups: groups)
    }

    private static func recordGroupTitle(
        _ title: String,
        updatedAt: Date,
        groupID: DownloadGroupID,
        in groupTitles: inout [DownloadGroupID: DownloadManagementGroupTitle]
    ) {
        guard let title = title.nilIfBlank else { return }
        if let existing = groupTitles[groupID], existing.updatedAt > updatedAt {
            return
        }
        groupTitles[groupID] = DownloadManagementGroupTitle(title: title, updatedAt: updatedAt)
    }

}

private struct DownloadManagementGroupTitle {
    var title: String
    var updatedAt: Date
}

private struct DownloadManagementEntryBuilder {
    var id: DownloadEntryID
    var title: String
    var imageURLStrings: Set<String> = []
    var byteCount = 0
    var state: DownloadEntryState
    var updatedAt: Date
    var workID: DownloadWorkID?

    func entry(byteCount: Int) -> DownloadManagementEntry {
        DownloadManagementEntry(
            id: id,
            title: title,
            byteCount: byteCount,
            state: state,
            updatedAt: updatedAt,
            workID: workID
        )
    }
}
