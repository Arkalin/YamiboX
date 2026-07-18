import Foundation
@preconcurrency import GRDB

actor DiskCacheStore {
    struct CacheEntry: Sendable {
        var namespace: String
        var key: String
        var createdAt: Date
        var lastAccessedAt: Date

        init(namespace: String, key: String, createdAt: Date, lastAccessedAt: Date) {
            self.namespace = namespace
            self.key = key
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
        }
    }

    /// Minimum age of `last_accessed_at` before a cache hit rewrites it.
    private static let lastAccessedTouchInterval: TimeInterval = 300

    private let writer: any DatabaseWriter
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        writer: any DatabaseWriter,
        rootDirectory: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writer = writer
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.now = now
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func set<Value: Encodable & Sendable>(_ value: Value, namespace: String, key: String) async throws {
        let resolvedNamespace = try validatedComponent(namespace, label: "namespace")
        let resolvedKey = try validatedComponent(key, label: "cache key")
        let namespaceDirectory = cacheDirectory(for: resolvedNamespace)
        if !fileManager.fileExists(atPath: namespaceDirectory.path) {
            try fileManager.createDirectory(at: namespaceDirectory, withIntermediateDirectories: true)
        }

        let data = try encoder.encode(value)
        try data.write(to: cacheFileURL(namespace: resolvedNamespace, key: resolvedKey), options: [.atomic])

        let timestamp = now().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO cache_entries (namespace, cache_key, created_at, last_accessed_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(namespace, cache_key) DO UPDATE SET
                    created_at = excluded.created_at,
                    last_accessed_at = excluded.last_accessed_at
                """,
                arguments: [resolvedNamespace, resolvedKey, timestamp, timestamp]
            )
        }
    }

    func get<Value: Decodable & Sendable>(
        _ type: Value.Type = Value.self,
        namespace: String,
        key: String,
        ttl: TimeInterval? = nil
    ) async throws -> Value? {
        let resolvedNamespace = try validatedComponent(namespace, label: "namespace")
        let resolvedKey = try validatedComponent(key, label: "cache key")
        guard let entry = try await cacheEntry(namespace: resolvedNamespace, key: resolvedKey) else { return nil }

        if let ttl, now().timeIntervalSince(entry.createdAt) > ttl {
            try await removeValidated(namespace: resolvedNamespace, key: resolvedKey)
            return nil
        }

        let fileURL = cacheFileURL(namespace: resolvedNamespace, key: resolvedKey)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            try await removeMetadata(namespace: resolvedNamespace, key: resolvedKey)
            return nil
        }

        do {
            let value = try decoder.decode(Value.self, from: try Data(contentsOf: fileURL))
            // Coarse LRU: skip the per-hit write transaction while the stored
            // timestamp is fresh enough — eviction only needs minute-level order.
            if now().timeIntervalSince(entry.lastAccessedAt) >= Self.lastAccessedTouchInterval {
                try await touchLastAccessedAt(namespace: resolvedNamespace, key: resolvedKey)
            }
            return value
        } catch {
            YamiboLog.offlineCache.warning("Discarding unreadable cache entry \(resolvedNamespace)/\(resolvedKey): \(error)")
            try await removeValidated(namespace: resolvedNamespace, key: resolvedKey)
            return nil
        }
    }

    func remove(namespace: String, key: String) async throws {
        try await removeValidated(namespace: try validatedComponent(namespace, label: "namespace"), key: try validatedComponent(key, label: "cache key"))
    }

    func clearNamespace(_ namespace: String) async throws {
        let resolvedNamespace = try validatedComponent(namespace, label: "namespace")
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM cache_entries WHERE namespace = ?", arguments: [resolvedNamespace])
        }
        let directory = cacheDirectory(for: resolvedNamespace)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func deleteKeys(namespace: String, matchingPrefix prefix: String) async throws {
        let resolvedNamespace = try validatedComponent(namespace, label: "namespace")
        let resolvedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = try await writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT cache_key FROM cache_entries WHERE namespace = ? AND cache_key LIKE ? ESCAPE '\\'",
                arguments: [resolvedNamespace, "\(Self.likeEscaped(resolvedPrefix))%"]
            )
        }
        for key in keys {
            try await removeValidated(namespace: resolvedNamespace, key: key)
        }
    }

    func trimNamespace(_ namespace: String, maximumEntryCount: Int) async throws {
        let resolvedNamespace = try validatedComponent(namespace, label: "namespace")
        guard maximumEntryCount >= 0 else { throw YamiboPersistenceError(context: "Invalid cache entry limit") }
        let keys = try await writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT cache_key
                FROM cache_entries
                WHERE namespace = ?
                ORDER BY last_accessed_at DESC, cache_key ASC
                LIMIT -1 OFFSET ?
                """,
                arguments: [resolvedNamespace, maximumEntryCount]
            )
        }
        for key in keys {
            try await removeValidated(namespace: resolvedNamespace, key: key)
        }
    }

    func entries(namespace: String) async throws -> [CacheEntry] {
        let resolvedNamespace = try validatedComponent(namespace, label: "namespace")
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT namespace, cache_key, created_at, last_accessed_at
                FROM cache_entries
                WHERE namespace = ?
                ORDER BY cache_key ASC
                """,
                arguments: [resolvedNamespace]
            )
            return rows.map { row in
                CacheEntry(
                    namespace: row["namespace"],
                    key: row["cache_key"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    lastAccessedAt: Date(timeIntervalSince1970: row["last_accessed_at"])
                )
            }
        }
    }

    func fileURL(namespace: String, key: String) throws -> URL {
        try cacheFileURL(
            namespace: validatedComponent(namespace, label: "namespace"),
            key: validatedComponent(key, label: "cache key")
        )
    }

    private func cacheEntry(namespace: String, key: String) async throws -> CacheEntry? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT namespace, cache_key, created_at, last_accessed_at
                FROM cache_entries
                WHERE namespace = ? AND cache_key = ?
                """,
                arguments: [namespace, key]
            ) else {
                return nil
            }
            return CacheEntry(
                namespace: row["namespace"],
                key: row["cache_key"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                lastAccessedAt: Date(timeIntervalSince1970: row["last_accessed_at"])
            )
        }
    }

    private func touchLastAccessedAt(namespace: String, key: String) async throws {
        let timestamp = now().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE cache_entries SET last_accessed_at = ? WHERE namespace = ? AND cache_key = ?",
                arguments: [timestamp, namespace, key]
            )
        }
    }

    private func removeValidated(namespace: String, key: String) async throws {
        do {
            try fileManager.removeItem(at: cacheFileURL(namespace: namespace, key: key))
        } catch {
            YamiboLog.offlineCache.warning("Failed to remove cache file for \(namespace)/\(key), leaving an orphaned file: \(error)")
        }
        try await removeMetadata(namespace: namespace, key: key)
    }

    private func removeMetadata(namespace: String, key: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM cache_entries WHERE namespace = ? AND cache_key = ?",
                arguments: [namespace, key]
            )
        }
    }

    private func cacheDirectory(for namespace: String) -> URL {
        YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory, fileManager: fileManager)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private func cacheFileURL(namespace: String, key: String) -> URL {
        cacheDirectory(for: namespace).appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func validatedComponent(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              trimmed != ".",
              trimmed != ".." else {
            throw YamiboPersistenceError(context: "Invalid \(label)")
        }
        return trimmed
    }

    private static func likeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
