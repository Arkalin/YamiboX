import CryptoKit
import Foundation
@preconcurrency import GRDB

extension DownloadStore: ForumAttachmentDownloadStoring {
    func enqueueAttachmentDownload(_ request: ForumAttachmentDownloadRequest) async throws -> ForumAttachmentEnqueueResult {
        try await ensureQueueRecovered()
        guard ForumWebPagePolicy.requiresForumHandling(request.attachment.url),
              !ForumWebPagePolicy.requiresConfirmationToLoad(request.attachment.url),
              ForumWebPagePolicy.requiresForumHandling(request.refererURL),
              !request.threadID.isEmpty else { throw ForumPageError.invalidURL }
        var url = URLComponents(url: request.attachment.url, resolvingAgainstBaseURL: true)
        url?.fragment = nil
        guard let canonicalURL = url?.url else { throw ForumPageError.invalidURL }
        let ownerKey = "\(YamiboForumEnvironment.current.baseURL.absoluteString)|\(request.threadID)"
        let entryKey = SHA256.hash(data: Data("\(ownerKey)|\(canonicalURL.absoluteString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let data = try JSONEncoder().encode(request)
        let result = try await database.write { db -> ForumAttachmentEnqueueResult in
            if let row = try Row.fetchOne(db, sql: "SELECT file_name, directory_name FROM download_attachment_entries WHERE entry_key = ?", arguments: [entryKey]) {
                let name: String = row["file_name"]
                let directory: String = row["directory_name"]
                if fileManager.fileExists(atPath: attachmentsDirectory.appendingPathComponent(directory).appendingPathComponent(name).path) {
                    return .alreadyDownloaded
                }
                try db.execute(sql: "DELETE FROM download_attachment_entries WHERE entry_key = ?", arguments: [entryKey])
            }
            if try Self.rawWork(readerKind: .attachment, ownerKey: ownerKey, entryKey: entryKey, in: db) != nil {
                // Refresh display/request metadata without replacing the queued work.
                try db.execute(sql: "UPDATE download_attachment_requests SET request_json = ? WHERE owner_name = ? AND tid = ?",
                               arguments: [data, ownerKey, entryKey])
                return .alreadyQueued
            }
            _ = try Self.enqueueNewWork(readerKind: .attachment, ownerKey: ownerKey, ownerTitle: request.threadTitle,
                                       entryKey: entryKey, title: request.attachment.fileName, targetImageURLs: [],
                                       retainsInlineImages: false, in: db)
            try db.execute(sql: "INSERT INTO download_attachment_requests VALUES (?, ?, ?, ?)",
                           arguments: [DownloadReaderKind.attachment.rawValue, ownerKey, entryKey, data])
            return .enqueued
        }
        notifyDownloadDidChange()
        return result
    }

    func attachmentDownloadRequest(workID: DownloadWorkID) async throws -> ForumAttachmentDownloadRequest {
        try await database.read { db in
            guard let work = try Self.rawWork(workID: workID.rawValue, readerKind: .attachment, in: db),
                  let data = try Data.fetchOne(db, sql: "SELECT request_json FROM download_attachment_requests WHERE owner_name = ? AND tid = ?",
                                              arguments: [work.ownerKey, work.entryKey]) else { throw CancellationError() }
            return try JSONDecoder().decode(ForumAttachmentDownloadRequest.self, from: data)
        }
    }

    func finishAttachmentDownload(workID: DownloadWorkID, file: ForumAttachmentFile) async throws {
        // File publication and work deletion share the DB writer with cancellation.
        // A retired or replaced work can never publish a completed attachment.
        let directoryName = UUID().uuidString
        let directory = attachmentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try await database.write { db in
                try Task.checkCancellation()
                guard let work = try Self.rawWork(workID: workID.rawValue, readerKind: .attachment, in: db) else { throw CancellationError() }
                try Self.createBackupExcludedDirectory(at: directory, fileManager: fileManager)
                do {
                    try file.data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
                    try Task.checkCancellation()
                    try db.execute(sql: "INSERT OR REPLACE INTO download_attachment_entries VALUES (?, ?, ?, ?, ?, ?, ?)",
                                   arguments: [work.entryKey, work.ownerKey, work.ownerTitle, file.name, directoryName, file.data.count, Date().timeIntervalSince1970])
                    try Self.deleteWork(readerKind: "attachment", ownerName: work.ownerKey, tid: work.entryKey, in: db)
                } catch {
                    try? fileManager.removeItem(at: directory)
                    throw error
                }
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        notifyDownloadDidChange()
    }

    func downloadedAttachmentURL(id: DownloadEntryID) async throws -> URL {
        guard id.readerKind == .attachment else { throw ForumPageError.invalidURL }
        return try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT file_name, directory_name FROM download_attachment_entries WHERE entry_key = ? AND owner_name = ?",
                                                arguments: [id.entryKey, id.ownerKey]) else { throw CocoaError(.fileNoSuchFile) }
            let name: String = row["file_name"]
            let directory: String = row["directory_name"]
            let url = attachmentsDirectory.appendingPathComponent(directory).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            return url
        }
    }

    func removeAttachmentDownloads(ownerKey: String, entryKey: String? = nil) async throws {
        try await database.write { db in
            let predicate = "owner_name = ?" + (entryKey == nil ? "" : " AND entry_key = ?")
            let arguments = StatementArguments(entryKey.map { [ownerKey, $0] } ?? [ownerKey])
            let keys = try String.fetchAll(db, sql: "SELECT directory_name FROM download_attachment_entries WHERE \(predicate)", arguments: arguments)
            for key in keys {
                let directory = attachmentsDirectory.appendingPathComponent(key)
                if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
            }
            try db.execute(sql: "DELETE FROM download_attachment_entries WHERE \(predicate)", arguments: arguments)
            try db.execute(sql: "DELETE FROM download_works WHERE reader_kind = 'attachment' AND owner_name = ?" + (entryKey == nil ? "" : " AND tid = ?"), arguments: arguments)
        }
        notifyDownloadDidChange()
    }
}
