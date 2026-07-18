import Foundation
@preconcurrency import GRDB

/// Owns the shared `yamibox.sqlite` pool: path resolution, pool configuration, and
/// aggregation of the feature schema modules that own the actual tables.
enum YamiboDatabase {
    static let databaseFileName = "yamibox.sqlite"
    static let cacheDirectoryName = "yamibox-cache"

    /// Every feature module owning tables in `yamibox.sqlite`.
    private static let schemaModules: [any DatabaseSchemaModule.Type] = [
        DiskCacheDatabaseSchema.self,
        LibraryDatabaseSchema.self,
        FavoriteUpdateDatabaseSchema.self,
        LikeDatabaseSchema.self,
        ReaderDatabaseSchema.self,
        BrowsingHistoryDatabaseSchema.self,
    ]

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YamiboX", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("YamiboX", isDirectory: true)
    }

    /// Root for the regenerable `yamibox-cache` file cache. Lives under
    /// `Library/Caches`, which the OS keeps out of backups and may purge under
    /// disk pressure; anything that must survive belongs under
    /// `defaultRootDirectory()` instead.
    static func defaultCacheRootDirectory(fileManager: FileManager = .default) -> URL {
        let cachesBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Caches", isDirectory: true)
        return cachesBase.appendingPathComponent("YamiboX", isDirectory: true)
    }

    static func databaseURL(rootDirectory: URL? = nil, fileManager: FileManager = .default) -> URL {
        (rootDirectory ?? defaultRootDirectory(fileManager: fileManager))
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    static func cacheDirectoryURL(rootDirectory: URL? = nil, fileManager: FileManager = .default) -> URL {
        (rootDirectory ?? defaultRootDirectory(fileManager: fileManager))
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    static func openPool(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> DatabasePool {
        let root = rootDirectory ?? defaultRootDirectory(fileManager: fileManager)
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var configuration = Configuration()
        // Several pools may point at the same database file (app plus tests);
        // wait for concurrent writers instead of failing with SQLITE_BUSY.
        configuration.busyMode = .timeout(5)
        let databaseURL = databaseURL(rootDirectory: root, fileManager: fileManager)
        do {
            return try openAndMigratePool(at: databaseURL, configuration: configuration)
        } catch let error as DatabaseError where corruptionResultCodes.contains(error.resultCode) {
            // Every store treats "cannot open the database" as fatal, so a
            // corrupt file would otherwise crash-loop the app on each launch
            // with no self-serve way out. Losing local cache/bookkeeping
            // beats being unable to launch: quarantine the corpse for
            // diagnosis and start over with an empty database.
            YamiboLog.persistence.error("yamibox.sqlite is corrupt; quarantining it and recreating: \(error)")
            try quarantineCorruptDatabase(at: databaseURL, fileManager: fileManager)
            return try openAndMigratePool(at: databaseURL, configuration: configuration)
        }
    }

    private static let corruptionResultCodes: [ResultCode] = [.SQLITE_CORRUPT, .SQLITE_NOTADB]

    private static func openAndMigratePool(at databaseURL: URL, configuration: Configuration) throws -> DatabasePool {
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try migrate(pool)
        return pool
    }

    /// Moves the database file (and its WAL/SHM sidecars) aside under a
    /// timestamped `.corrupt-*` name instead of deleting it, so the corpse
    /// stays available for diagnosis.
    private static func quarantineCorruptDatabase(at databaseURL: URL, fileManager: FileManager) throws {
        let suffix = ".corrupt-\(Int(Date.now.timeIntervalSince1970))"
        for sidecar in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + sidecar)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: databaseURL.path + suffix + sidecar)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false
        for module in schemaModules {
            module.registerMigrations(in: &migrator)
        }
        try migrator.migrate(writer)
    }

    static func reset(
        writer: any DatabaseWriter,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try writer.write { db in
            for module in schemaModules {
                try module.erase(in: db)
            }
        }
        let cacheDirectory = cacheDirectoryURL(rootDirectory: rootDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
    }
}
