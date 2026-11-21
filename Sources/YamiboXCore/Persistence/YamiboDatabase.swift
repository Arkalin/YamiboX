import Foundation
@preconcurrency import GRDB

public enum YamiboDatabaseStartupError: LocalizedError, Sendable {
    case unavailable
    case newerSchema
    case corruptionRecoveryFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n.string("app.startup.database_unavailable")
        case .newerSchema: L10n.string("app.startup.database_newer")
        case .corruptionRecoveryFailed: L10n.string("app.startup.database_recovery_failed")
        }
    }
}

enum YamiboDatabase {
    static let databaseFileName = "yamibox.sqlite"
    static let cacheDirectoryName = "yamibox-cache"

    private static let schemaModules: [any DatabaseSchemaModule.Type] = [
        DiskCacheDatabaseSchema.self,
        LibraryDatabaseSchema.self,
        FavoriteUpdateDatabaseSchema.self,
        LikeDatabaseSchema.self,
        BookmarkDatabaseSchema.self,
        ReaderDatabaseSchema.self,
        BrowsingHistoryDatabaseSchema.self,
        ForumComposerDraftDatabaseSchema.self,
    ]

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YamiboX", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("YamiboX", isDirectory: true)
    }

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
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let databaseURL = databaseURL(rootDirectory: root, fileManager: fileManager)
        do {
            if !fileManager.fileExists(atPath: root.path) {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            }
            return try openAndMigratePool(at: databaseURL, configuration: configuration)
        } catch let error as YamiboDatabaseStartupError {
            throw error
        } catch let error as DatabaseError where corruptionResultCodes.contains(error.resultCode) {
            YamiboLog.persistence.error("yamibox.sqlite is corrupt; quarantining it and recreating: \(error)")
            do {
                try quarantineCorruptDatabase(at: databaseURL, fileManager: fileManager)
                return try openAndMigratePool(at: databaseURL, configuration: configuration)
            } catch {
                YamiboLog.persistence.error("Could not recover the corrupt application database: \(error)")
                throw YamiboDatabaseStartupError.corruptionRecoveryFailed
            }
        } catch {
            YamiboLog.persistence.error("Could not open or migrate the application database: \(error)")
            throw YamiboDatabaseStartupError.unavailable
        }
    }

    private static let corruptionResultCodes: [ResultCode] = [.SQLITE_CORRUPT, .SQLITE_NOTADB]

    private static func openAndMigratePool(at databaseURL: URL, configuration: Configuration) throws -> DatabasePool {
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try migrate(pool)
        return pool
    }

    private static func quarantineCorruptDatabase(at databaseURL: URL, fileManager: FileManager) throws {
        let suffix = ".corrupt-\(UUID().uuidString)"
        for sidecar in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + sidecar)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: databaseURL.path + suffix + sidecar)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false
        for module in schemaModules {
            module.registerMigrations(in: &migrator)
        }
        MangaIdentityMigrationV1.register(in: &migrator)
        DownloadNamingMigration.register(in: &migrator)
        ForumAttachmentDownloadSchema.register(in: &migrator)
        FavoriteUpdateDatabaseSchema.registerNotificationBadgeMigration(in: &migrator)
        guard try !writer.read(migrator.hasBeenSuperseded) else {
            throw YamiboDatabaseStartupError.newerSchema
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
            try db.execute(sql: "DELETE FROM manga_identity_aliases; DELETE FROM manga_identity_redirects; DELETE FROM manga_identities")
        }
        let cacheDirectory = cacheDirectoryURL(rootDirectory: rootDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
    }
}
