import CryptoKit
import Foundation
@preconcurrency import GRDB

extension DownloadStore: YamiboOfflineImageDataProviding {
    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data? {
        if let ownerName = scope.ownerName {
            return await mangaOfflineImageData(for: url, ownerName: ownerName, tid: scope.tid)
        }
        return await novelOfflineImageData(for: url, threadID: scope.tid)
    }
}

extension DownloadStore {
    private func mangaOfflineImageData(for imageURL: URL, ownerName: String, tid: String) async -> Data? {
        await ensureQueueRecoveredBestEffort()
        let imageURLString = imageURL.absoluteString
        let fileName: String?
        do {
            fileName = try await database.read { db in
                try Self.mangaOfflineImageFileName(
                    imageURLString: imageURLString,
                    ownerName: ownerName,
                    tid: tid,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                )
            }
        } catch {
            YamiboLog.download.error("Failed to resolve manga offline image file name for \(imageURLString): \(error)")
            return nil
        }
        guard let fileName else { return nil }
        return await offlineImageData(imageURLString: imageURLString, fileName: fileName)
    }

    func offlineImageData(for imageURL: URL) async -> Data? {
        await ensureQueueRecoveredBestEffort()
        let imageURLString = imageURL.absoluteString
        let fileName: String?
        do {
            fileName = try await database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT file_name FROM download_image_assets WHERE image_url = ?",
                    arguments: [imageURLString]
                )
            }
        } catch {
            YamiboLog.download.error("Failed to resolve offline image file name for \(imageURLString): \(error)")
            return nil
        }
        guard let fileName else {
            return nil
        }

        return await offlineImageData(imageURLString: imageURLString, fileName: fileName)
    }

    /// Existence-only variant of `offlineImageData(for:)`: a point lookup on
    /// the `image_url` primary key plus a file-existence probe, mirroring
    /// `isMembershipComplete`. It never reads file contents, so completeness
    /// reconciliation over a chapter's worth of images stays O(images) cheap
    /// metadata checks instead of loading every downloaded image into memory.
    /// Deliberately read-only: unlike `offlineImageData(for:)` it does not
    /// delete the DB row when the file has gone missing, the same trade-off
    /// `isMembershipComplete` already makes for its downloaded/notDownloaded decisions.
    func hasOfflineImage(for imageURL: URL) async -> Bool {
        await ensureQueueRecoveredBestEffort()
        let imageURLString = imageURL.absoluteString
        let fileName: String?
        do {
            fileName = try await database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT file_name FROM download_image_assets WHERE image_url = ?",
                    arguments: [imageURLString]
                )
            }
        } catch {
            YamiboLog.download.error("Failed to resolve offline image file name for \(imageURLString): \(error)")
            return false
        }
        guard let fileName else {
            return false
        }
        return fileManager.fileExists(
            atPath: imagesDirectory.appendingPathComponent(fileName, isDirectory: false).path
        )
    }

    func novelOfflineImageData(for imageURL: URL, threadID: String) async -> Data? {
        await ensureQueueRecoveredBestEffort()
        let imageURLString = imageURL.absoluteString
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }
        let fileName: String?
        do {
            fileName = try await database.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                    SELECT assets.file_name
                    FROM download_novel_entry_images AS entry_images
                    JOIN download_novel_entries AS entries
                        ON entries.entry_key = entry_images.entry_key
                    JOIN download_image_assets AS assets
                        ON assets.image_url = entry_images.image_url
                    WHERE entry_images.image_url = ?
                        AND entries.thread_id = ?
                    ORDER BY entries.updated_at DESC, entry_images.entry_key ASC
                    LIMIT 1
                    """,
                    arguments: [imageURLString, normalizedThreadID]
                )
            }
        } catch {
            YamiboLog.download.error("Failed to resolve novel offline image file name for \(imageURLString): \(error)")
            return nil
        }
        guard let fileName else {
            return nil
        }

        return await offlineImageData(imageURLString: imageURLString, fileName: fileName)
    }

    private func offlineImageData(imageURLString: String, fileName: String) async -> Data? {
        let fileURL = imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            do {
                try await database.write { db in
                    try Self.deleteImage(imageURLString: imageURLString, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db)
                }
            } catch {
                YamiboLog.download.warning("Failed to remove orphaned offline image DB row for \(imageURLString) after missing file \(fileName): \(error)")
            }
            return nil
        }
        return data
    }

    func saveOfflineImageData(_ data: Data, for imageURL: URL) async throws {
        try await ensureQueueRecovered()
        do {
            let imageURLString = imageURL.absoluteString
            let fileName = imageFileName(for: imageURL)
            if !data.isEmpty {
                try ensureImagesDirectoryExists()
                let fileURL = imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
                try data.write(to: fileURL, options: [.atomic])
            }

            try await database.write { db in
                guard !data.isEmpty else {
                    try Self.deleteImage(imageURLString: imageURLString, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db)
                    return
                }

                if let oldFileName = try String.fetchOne(
                    db,
                    sql: "SELECT file_name FROM download_image_assets WHERE image_url = ?",
                    arguments: [imageURLString]
                ), oldFileName != fileName {
                    do {
                        try fileManager.removeItem(at: imagesDirectory.appendingPathComponent(oldFileName, isDirectory: false))
                    } catch {
                        YamiboLog.download.error("Failed to remove superseded offline image file \(oldFileName): \(error)")
                    }
                }
                try db.execute(
                    sql: """
                    INSERT INTO download_image_assets (image_url, file_name, byte_count)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [imageURLString, fileName, data.count]
                )

                // Narrowed via the image_url index instead of scanning every downloaded chapter:
                // only chapters that actually reference this image can possibly have just
                // become complete.
                let candidateOwnerTIDs = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT owner_name, tid
                    FROM download_manga_entry_images
                    WHERE image_url = ?
                    """,
                    arguments: [imageURLString]
                )
                for row in candidateOwnerTIDs {
                    let ownerName = try Self.canonicalMangaOwnerKey(row["owner_name"], in: db)
                    let tid: String = row["tid"]
                    if try Self.hasMissingMangaImage(
                        ownerName: ownerName, tid: tid, cache: missingMangaImageCache, in: db
                    ) { continue }
                    guard let membership = try Self.membership(
                        ownerName: ownerName,
                        tid: tid,
                        fileManager: fileManager,
                        mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                        sourcePageCache: sourcePageCache,
                        in: db
                    ) else {
                        continue
                    }
                    if try Self.isMembershipComplete(membership, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db) {
                        try Self.deleteWork(ownerName: membership.ownerName, tid: membership.tid, in: db)
                    }
                }
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    /// A known absent asset proves this chapter cannot be complete. Keep one
    /// bounded hint, rather than hydrating all chapter URLs after every image.
    /// The final check still validates the source page and every asset file.
    private static func hasMissingMangaImage(
        ownerName: String,
        tid: String,
        cache: NSCache<NSString, MangaMissingImageCacheEntry>,
        in db: Database
    ) throws -> Bool {
        let key = "\(ownerName.utf8.count):\(ownerName)\(tid)" as NSString
        if let missing = cache.object(forKey: key),
           try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM download_manga_entry_images
                WHERE owner_name = ? AND tid = ? AND manual_order = ? AND image_url = ?
                    AND NOT EXISTS(
                        SELECT 1 FROM download_image_assets WHERE image_url = ?
                    )
            )
            """, arguments: [ownerName, tid, missing.manualOrder, missing.imageURL, missing.imageURL]) == true {
            return true
        }
        cache.removeObject(forKey: key)
        let missing = try Row.fetchOne(db, sql: """
            SELECT images.image_url, images.manual_order
            FROM download_manga_entry_images AS images
            LEFT JOIN download_image_assets AS assets ON assets.image_url = images.image_url
            WHERE images.owner_name = ? AND images.tid = ? AND assets.image_url IS NULL
            ORDER BY images.manual_order DESC
            LIMIT 1
            """, arguments: [ownerName, tid])
        // Full membership reads parse and normalize URL strings. Preserve
        // that fallback for legacy rows not written as URL.absoluteString.
        guard let missing else { return false }
        let missingURL: String = missing["image_url"]
        guard URL(string: missingURL)?.absoluteString == missingURL else { return false }
        cache.setObject(MangaMissingImageCacheEntry(
            manualOrder: missing["manual_order"], imageURL: missingURL
        ), forKey: key)
        return true
    }

    func mangaDownloadDiskUsageByOwner() async -> [MangaDownloadOwnerUsage] {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                var imageURLsByOwner: [String: Set<String>] = [:]
                var byteCountByOwner: [String: Int] = [:]
                for membership in try Self.allMangaMemberships(
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                ) {
                    imageURLsByOwner[membership.ownerName, default: []].formUnion(membership.imageURLs.map(\.absoluteString))
                    byteCountByOwner[membership.ownerName, default: 0] += try Self.mangaEntryByteCount(
                        ownerName: membership.ownerName,
                        tid: membership.tid,
                        in: db
                    )
                }
                for work in try Self.allRawWorks(in: db) where work.readerKind == .manga {
                    imageURLsByOwner[work.ownerKey, default: []].formUnion((work.targetImageURLs + work.completedImageURLs).map(\.absoluteString))
                }

                var usage: [MangaDownloadOwnerUsage] = []
                for ownerName in Set(imageURLsByOwner.keys).union(byteCountByOwner.keys) {
                    var byteCount = byteCountByOwner[ownerName] ?? 0
                    byteCount += try Self.imageAssetByteCount(
                        forImageURLStrings: imageURLsByOwner[ownerName] ?? [],
                        in: db
                    )
                    usage.append(MangaDownloadOwnerUsage(ownerName: ownerName, byteCount: byteCount))
                }
                return usage.sorted { $0.ownerName.localizedStandardCompare($1.ownerName) == .orderedAscending }
            }
        } catch {
            YamiboLog.download.error("Failed to compute manga offline download disk usage by owner: \(error)")
            return []
        }
    }

    func ensureImagesDirectoryExists() throws {
        try ensureBaseDirectoryExists()
        if !fileManager.fileExists(atPath: imagesDirectory.path) {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        }
    }

    func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isMembershipComplete(
        _ membership: MangaDownloadMembership,
        fileManager: FileManager,
        imagesDirectory: URL,
        in db: Database
    ) throws -> Bool {
        guard membership.sourcePage.thread.tid == membership.tid else { return false }
        guard !membership.imageURLs.isEmpty else { return false }
        let urlStrings = Array(Set(membership.imageURLs.map(\.absoluteString)))
        for start in stride(from: 0, to: urlStrings.count, by: 200) {
            let chunk = Array(urlStrings[start ..< min(start + 200, urlStrings.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try Row.fetchAll(db,
                sql: "SELECT file_name FROM download_image_assets WHERE image_url IN (\(placeholders))",
                arguments: StatementArguments(chunk))
            guard rows.count == chunk.count else { return false }
            for row in rows {
                let fileName: String = row["file_name"]
                let fileURL = imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
                guard fileManager.fileExists(atPath: fileURL.path) else { return false }
            }
        }
        return true
    }

    /// Sums `byte_count` over a set of image URLs with one indexed
    /// `SUM ... WHERE image_url IN (...)` query per chunk, replacing the
    /// one-SELECT-per-URL loops that dominated management-snapshot and
    /// disk-usage builds. Chunked (same 200 bound as `ContentCoverStore`)
    /// because SQLite caps bound parameters per statement — historically 999 —
    /// and callers can pass a whole library's worth of URLs. Takes a `Set` so
    /// each URL contributes once, which matches both the replaced loops and
    /// the table's `image_url` primary key.
    static func imageAssetByteCount(forImageURLStrings imageURLStrings: Set<String>, in db: Database) throws -> Int {
        let allURLStrings = Array(imageURLStrings)
        let chunkSize = 200
        var total = 0
        for start in stride(from: 0, to: allURLStrings.count, by: chunkSize) {
            let chunk = Array(allURLStrings[start ..< min(start + chunkSize, allURLStrings.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            total += try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(byte_count), 0) FROM download_image_assets WHERE image_url IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            ) ?? 0
        }
        return total
    }

    static func removeUnreferencedImages(
        candidateImageURLs: [URL],
        fileManager: FileManager,
        imagesDirectory: URL,
        in db: Database
    ) throws {
        let candidates = Set(candidateImageURLs.map(\.absoluteString))
        guard !candidates.isEmpty else { return }
        for imageURLString in candidates {
            guard try !isImageReferenced(imageURLString, in: db) else { continue }
            try deleteImage(imageURLString: imageURLString, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db)
        }
    }

    private func imageFileName(for imageURL: URL) -> String {
        let rawExtension = imageURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExtension = sanitizedFileExtension(rawExtension.isEmpty ? "bin" : rawExtension)
        return "offline_image_\(sha256Hex(imageURL.absoluteString)).\(safeExtension)"
    }

    private func sanitizedFileExtension(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: #"[^A-Za-z0-9]"#, with: "", options: .regularExpression)
        return sanitized.isEmpty ? "bin" : sanitized
    }

    /// Point lookups on the four `image_url` indexes: O(log n) per candidate,
    /// instead of materializing every reference row for each GC pass.
    private static func isImageReferenced(_ imageURLString: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(SELECT 1 FROM download_manga_entry_images WHERE image_url = ?)
                OR EXISTS(SELECT 1 FROM download_novel_entry_images WHERE image_url = ?)
                OR EXISTS(SELECT 1 FROM download_work_images WHERE image_url = ?)
                OR EXISTS(SELECT 1 FROM download_completed_images WHERE image_url = ?)
            """,
            arguments: [imageURLString, imageURLString, imageURLString, imageURLString]
        ) ?? false
    }

    private static func deleteImage(
        imageURLString: String,
        fileManager: FileManager,
        imagesDirectory: URL,
        in db: Database
    ) throws {
        if let fileName = try String.fetchOne(
            db,
            sql: "SELECT file_name FROM download_image_assets WHERE image_url = ?",
            arguments: [imageURLString]
        ) {
            do {
                try fileManager.removeItem(at: imagesDirectory.appendingPathComponent(fileName, isDirectory: false))
            } catch {
                YamiboLog.download.error("Failed to remove offline image file \(fileName): \(error)")
            }
        }
        try db.execute(sql: "DELETE FROM download_image_assets WHERE image_url = ?", arguments: [imageURLString])
    }
}
