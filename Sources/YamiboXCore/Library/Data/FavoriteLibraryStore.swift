import Foundation
@preconcurrency import GRDB

public actor FavoriteLibraryStore {
    public static let didChangeNotification = Notification.Name("yamibox.favoriteLibraryStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    nonisolated(unsafe) private static var databasePoolCache: [String: DatabasePool] = [:]
    private static let databasePoolCacheLock = NSLock()

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let key: String
    private let database: DatabasePool

    public init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.favoriteLibrary.localFirst"
    ) {
        self.defaults = defaults
        self.key = key
        self.database = Self.openDatabase(defaults: defaults, key: key)
    }

    init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.favoriteLibrary.localFirst",
        databasePool: DatabasePool
    ) {
        self.defaults = defaults
        self.key = key
        self.database = databasePool
    }

    /// Throws instead of returning an empty document: `save` replaces the
    /// whole database, so a load-modify-save writer that mistakes a transient
    /// read failure (SQLITE_BUSY, IO error, cancellation) for "library is
    /// empty" would wipe every favorite on its next save.
    public func load() async throws -> FavoriteLibraryDocument {
        do {
            return try await database.read { db in
                try Self.loadDocument(in: db)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Applies `transform` to the persisted document inside one write
    /// transaction — the read, mutation, and save cannot interleave with any
    /// other writer, so concurrent read-modify-write cycles never overwrite
    /// each other. Throwing from `transform` rolls the transaction back and
    /// rethrows the caller's error unchanged.
    @discardableResult
    public func update<T: Sendable>(
        _ transform: @escaping @Sendable (inout FavoriteLibraryDocument) throws -> T
    ) async throws -> T {
        do {
            let result = try await database.write { db in
                var document = try Self.loadDocument(in: db)
                let result: T
                do {
                    result = try transform(&document)
                } catch {
                    throw TransformFailure(underlying: error)
                }
                try Self.save(document, in: db)
                return result
            }
            postChangeNotification()
            return result
        } catch let failure as TransformFailure {
            throw failure.underlying
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    private struct TransformFailure: Error {
        let underlying: any Error
    }

    public func hasStoredDocument() async -> Bool {
        (try? await database.read { db in
            guard let document = try Self.storedDocument(in: db) else { return false }
            return !document.items.isEmpty
                || !document.collections.isEmpty
                || !document.tags.isEmpty
                || document.categories.contains { $0.id != FavoriteCategory.defaultID }
        }) ?? false
    }

    public func save(_ document: FavoriteLibraryDocument) async throws {
        do {
            try await database.write { db in
                try Self.save(document, in: db)
            }
            postChangeNotification()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clearAll() async throws {
        try await database.write { db in
            // Favorites-scoped wipe: covers are content metadata and survive
            // clearing the library (only the app-level reset erases them).
            try LibraryDatabaseSchema.deleteAllRows(in: db)
        }
        postChangeNotification()
    }

    private static func openDatabase(defaults: UserDefaults, key: String) -> DatabasePool {
        do {
            if defaults === UserDefaults.standard {
                return try cachedDatabasePool(rootDirectory: YamiboDatabase.defaultRootDirectory())
            }
            let idKey = "\(key).grdbDatabaseID"
            let databaseID: String
            if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
                databaseID = existing
            } else {
                databaseID = UUID().uuidString
                defaults.set(databaseID, forKey: idKey)
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("yamibo-x-local-favorite-library", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try cachedDatabasePool(rootDirectory: root)
        } catch {
            fatalError("Failed to open FavoriteLibraryStore database: \(error)")
        }
    }

    private static func cachedDatabasePool(rootDirectory: URL) throws -> DatabasePool {
        let key = rootDirectory.standardizedFileURL.path
        databasePoolCacheLock.lock()
        defer { databasePoolCacheLock.unlock() }
        if let pool = databasePoolCache[key] {
            return pool
        }

        let pool = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
        databasePoolCache[key] = pool
        return pool
    }

    private static func loadDocument(in db: Database) throws -> FavoriteLibraryDocument {
        try storedDocument(in: db) ?? FavoriteLibraryDocument()
    }

    private static func storedDocument(in db: Database) throws -> FavoriteLibraryDocument? {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT document_json FROM favorite_library_document WHERE id = 1"
        ) else {
            return nil
        }
        return try JSONDecoder().decode(FavoriteLibraryDocument.self, from: Data(json.utf8))
    }

    private static func save(_ document: FavoriteLibraryDocument, in db: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(canonicalized(document)), as: UTF8.self)
        try db.execute(
            sql: """
            INSERT INTO favorite_library_document (id, document_json, updated_at)
            VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                document_json = excluded.document_json,
                updated_at = excluded.updated_at
            """,
            arguments: [json, Date().timeIntervalSince1970]
        )
    }

    /// Stored documents stay canonical: the memberwise initializer normalizes
    /// categories (default ensured, sorted) and items (validated, sorted by
    /// id) — Codable decoding bypasses it, so save is where canonical form is
    /// enforced. Collections and tags get the ordering the relational schema
    /// used to impose via ORDER BY.
    private static func canonicalized(_ document: FavoriteLibraryDocument) -> FavoriteLibraryDocument {
        FavoriteLibraryDocument(
            categories: document.categories,
            collections: document.collections.sorted {
                if $0.categoryID != $1.categoryID { return $0.categoryID < $1.categoryID }
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            },
            items: document.items,
            tags: document.tags.sorted {
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
        )
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }
}
