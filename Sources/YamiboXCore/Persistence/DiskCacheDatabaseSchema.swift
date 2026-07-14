import Foundation
@preconcurrency import GRDB

/// Schema for the generic disk cache metadata managed by `DiskCacheStore`.
///
/// The `cache_entries` table stores thin LRU/TTL metadata for JSON payloads kept on
/// disk under `YamiboDatabase.cacheDirectoryName`, shared by forum and reader caches.
enum DiskCacheDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("disk_cache.v1") { db in
            try db.create(table: "cache_entries") { table in
                table.column("namespace", .text).notNull()
                table.column("cache_key", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("last_accessed_at", .double).notNull()
                table.primaryKey(["namespace", "cache_key"], onConflict: .replace)
            }
            try db.create(index: "cache_entries_namespace_last_accessed_idx", on: "cache_entries", columns: ["namespace", "last_accessed_at"])
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM cache_entries")
    }
}
