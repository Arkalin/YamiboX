import Foundation
@preconcurrency import GRDB

/// Old names are intentionally confined to upgrade code and frozen migrations.
enum DownloadNamingMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        // Keep FK enforcement enabled while renaming: Apple's SQLite can use legacy
        // ALTER TABLE behavior, which otherwise leaves references pointing at old names.
        migrator.registerMigration("downloads.v1.naming", foreignKeyChecks: .immediate) { db in
            // Identity v1 must finish against its original schema and payload path first.
            if let path = try String.fetchOne(db, sql: "SELECT file FROM pragma_database_list WHERE name = 'main'"), !path.isEmpty {
                try migrateFiles(root: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
            for newName in ReaderDatabaseSchema.downloadTableNamesInDeletionOrder.reversed() {
                let oldName = newName.replacingOccurrences(of: "download_", with: "offline_cache_")
                try db.rename(table: oldName, to: newName)
            }
            // SQLite updates foreign keys on table rename, but keeps index names.
            let indexes = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
            for index in indexes {
                let name: String = index["name"]
                guard name.hasPrefix("offline_cache_") else { continue }
                let sql: String = index["sql"]
                try db.execute(sql: "DROP INDEX \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"")
                try db.execute(sql: sql.replacingOccurrences(of: "offline_cache_", with: "download_"))
            }
            try db.execute(sql: "UPDATE download_works SET state = 'paused', current_bytes_per_second = 0 WHERE state = 'running'")
            try db.execute(sql: "INSERT OR REPLACE INTO download_queue_state(key, value) VALUES ('run_state', 'paused')")
        }
    }

    private static func migrateFiles(root: URL, fileManager: FileManager = .default) throws {
        let old = root.appendingPathComponent("offline-cache", isDirectory: true)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        guard fileManager.fileExists(atPath: old.path) else { return }
        for directory in [old, destination] where fileManager.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw YamiboPersistenceError(context: "Cannot migrate a symbolic link as a download directory")
            }
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw YamiboPersistenceError(context: "Legacy download directory is not a directory")
        }
        if !fileManager.fileExists(atPath: destination.path) {
            // Both paths are siblings on the same volume. The normal upgrade can
            // atomically move gigabytes of downloads without copying or extra disk space.
            var excludedSource = old
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedSource.setResourceValues(values)
            try fileManager.moveItem(at: old, to: destination)
            return
        }
        try DownloadStore.createBackupExcludedDirectory(at: destination, fileManager: fileManager)
        var excludedDestination = destination
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        try excludedDestination.setResourceValues(backupValues)
        var enumerationError: (any Error)?
        guard let enumerator = fileManager.enumerator(
            at: old, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw YamiboPersistenceError(context: "Could not enumerate legacy downloads")
        }
        var files: [(source: URL, target: URL)] = []
        for case let source as URL in enumerator {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw YamiboPersistenceError(context: "Cannot migrate a symbolic link in downloads")
            }
            let relative = String(source.path.dropFirst(old.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: target.path),
               try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw YamiboPersistenceError(context: "Cannot migrate over a symbolic link: \(relative)")
            }
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                if fileManager.fileExists(atPath: target.path), !fileManager.contentsEqual(atPath: source.path, andPath: target.path) {
                    throw YamiboPersistenceError(context: "Download migration found conflicting file: \(relative)")
                }
                files.append((source, target))
            }
        }
        if let enumerationError { throw enumerationError }
        // Keep all originals until every copy verifies. A crash leaves a safely retryable
        // pair of directories; no in-place overwrite or database reference rewrite is needed.
        for file in files {
            if !fileManager.fileExists(atPath: file.target.path) {
                let temporary = file.target.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString)")
                do {
                    try fileManager.copyItem(at: file.source, to: temporary)
                    try fileManager.moveItem(at: temporary, to: file.target)
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw error
                }
            }
            guard fileManager.contentsEqual(atPath: file.source.path, andPath: file.target.path) else {
                throw YamiboPersistenceError(context: "Download migration verification failed: \(file.source.lastPathComponent)")
            }
        }
        try fileManager.removeItem(at: old)
    }
}
