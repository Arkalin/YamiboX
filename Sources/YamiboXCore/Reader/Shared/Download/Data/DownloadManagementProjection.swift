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
        let mangaIdentities = try downloadMangaIdentitySnapshot(in: db)
        // Preserve the old scalar Int fetches' SQLite conversion, including
        // imported values that strict cached Row decoding would reject.
        var mangaBytes: [Data: [Data: Int]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT CAST(owner_name AS BLOB) AS raw_owner, CAST(tid AS BLOB) AS raw_entry,
                CAST(byte_count AS INTEGER) AS byte_count
            FROM download_manga_entries WHERE typeof(owner_name) = 'text' AND typeof(tid) = 'text'
            """) {
            mangaBytes[row["raw_owner"], default: [:]][row["raw_entry"]] = row["byte_count"]
        }
        var novelBytes: [Data: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT CAST(entry_key AS BLOB) AS raw_entry, CAST(byte_count AS INTEGER) AS byte_count FROM download_novel_entries WHERE typeof(entry_key) = 'text'") {
            novelBytes[row["raw_entry"]] = row["byte_count"]
        }

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
            let canonicalOwner = mangaIdentities.canonicalID(membership.ownerName)
            builder.byteCount += mangaBytes[Data(canonicalOwner.utf8)]?[Data(membership.tid.utf8)] ?? 0
            builder.imageURLStrings.formUnion(membership.imageURLs.map(\.absoluteString))
            builder.updatedAt = max(builder.updatedAt, membership.createdAt)
            builders[entryID] = builder
            let ownerTitle = mangaIdentities.title(for: canonicalOwner) ?? membership.ownerName
            recordGroupTitle(ownerTitle, updatedAt: membership.createdAt, groupID: entryID.groupID, in: &groupTitles)
        }

        try forEachNovelEntry(in: db) { entry in
            let entryID = entry.id
            var builder = builders[entryID] ?? DownloadManagementEntryBuilder(
                id: entryID,
                title: entry.title,
                state: .downloaded,
                updatedAt: entry.updatedAt
            )
            builder.title = entry.title
            builder.byteCount += novelBytes[Data(entryID.entryKey.utf8)] ?? 0
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

        let workImages = try managementWorkImageURLStrings(in: db)
        for work in try Row.fetchAll(db, sql: """
            SELECT reader_kind, work_id, owner_name, owner_title, tid, chapter_title, state, updated_at
            FROM download_works
            ORDER BY insertion_index ASC, reader_kind ASC, owner_name ASC, tid ASC
            """) {
            guard let kind = DownloadReaderKind(rawValue: work["reader_kind"] as String) else { continue }
            let owner: String = work["owner_name"]
            let entryKey: String = work["tid"]
            let fallbackOwnerTitle = (work["owner_title"] as String?) ?? owner
            let title = downloadEntryTitle(chapterTitle: work["chapter_title"], entryKey: entryKey)
            let updatedAt = downloadOptionalDate(from: work["updated_at"] as Double?) ?? Date(timeIntervalSince1970: 0)
            let imageOwner = kind == .manga ? mangaIdentities.canonicalID(owner) : owner
            let entryID = DownloadEntryID(
                readerKind: kind,
                ownerKey: owner,
                entryKey: entryKey
            )
            var builder = builders[entryID] ?? DownloadManagementEntryBuilder(
                id: entryID,
                title: title,
                state: .queued,
                updatedAt: updatedAt
            )
            builder.title = title
            builder.state = DownloadEntryState(workState: DownloadWorkState(rawValue: work["state"] as String) ?? .paused)
            builder.updatedAt = max(builder.updatedAt, updatedAt)
            builder.workID = DownloadWorkID(readerKind: kind, rawValue: work["work_id"])
            builder.imageURLStrings.formUnion(workImages[DownloadManagementWorkImageKey(readerKind: kind, ownerKey: imageOwner, entryKey: entryKey)] ?? [])
            builders[entryID] = builder
            let ownerTitle = kind == .manga ? mangaIdentities.title(for: imageOwner) ?? fallbackOwnerTitle : fallbackOwnerTitle
            recordGroupTitle(ownerTitle, updatedAt: updatedAt, groupID: entryID.groupID, in: &groupTitles)
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

    private static func managementWorkImageURLStrings(in db: Database) throws -> [DownloadManagementWorkImageKey: Set<String>] {
        var images: [DownloadManagementWorkImageKey: Set<String>] = [:]
        let kinds = DownloadReaderKind.allCases.map(\.rawValue)
        let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
        let rows = try Row.fetchCursor(db, sql: """
            SELECT reader_kind, CAST(owner_name AS BLOB) AS raw_owner, CAST(tid AS BLOB) AS raw_entry, image_url
            FROM download_work_images
            WHERE reader_kind IN (\(placeholders)) AND typeof(owner_name) = 'text' AND typeof(tid) = 'text'
            UNION ALL
            SELECT reader_kind, CAST(owner_name AS BLOB) AS raw_owner, CAST(tid AS BLOB) AS raw_entry, image_url
            FROM download_completed_images
            WHERE reader_kind IN (\(placeholders)) AND typeof(owner_name) = 'text' AND typeof(tid) = 'text'
            """, arguments: StatementArguments(kinds + kinds))
        while let row = try rows.next() {
            guard let kind = DownloadReaderKind(rawValue: row["reader_kind"] as String),
                  let url = URL(string: row["image_url"] as String) else { continue }
            let key = DownloadManagementWorkImageKey(readerKind: kind, ownerKey: row["raw_owner"] as Data, entryKey: row["raw_entry"] as Data)
            images[key, default: []].insert(url.absoluteString)
        }
        return images
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

private struct DownloadManagementWorkImageKey: Hashable {
    var readerKind: DownloadReaderKind
    var ownerKey: Data
    var entryKey: Data

    init(readerKind: DownloadReaderKind, ownerKey: String, entryKey: String) {
        self.init(readerKind: readerKind, ownerKey: Data(ownerKey.utf8), entryKey: Data(entryKey.utf8))
    }

    init(readerKind: DownloadReaderKind, ownerKey: Data, entryKey: Data) {
        self.readerKind = readerKind
        self.ownerKey = ownerKey
        self.entryKey = entryKey
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
