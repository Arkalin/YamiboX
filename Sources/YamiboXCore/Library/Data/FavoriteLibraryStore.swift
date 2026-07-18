import Foundation
@preconcurrency import GRDB

public actor FavoriteLibraryStore {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool

    public init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.favoriteLibrary.localFirst"
    ) {
        self.database = YamiboDatabasePoolResolver.resolvePool(defaults: defaults, key: key)
    }

    init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.favoriteLibrary.localFirst",
        databasePool: DatabasePool
    ) {
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
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
    /// used to impose via ORDER BY. Uses the internal 8-param initializer, not
    /// `document.rebuiltPreservingTombstones()`, because this also needs to
    /// substitute the freshly sorted collections/tags in the same call.
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
            },
            deletedItemIDs: document.deletedItemIDs,
            deletedCategoryIDs: document.deletedCategoryIDs,
            deletedCollectionIDs: document.deletedCollectionIDs,
            deletedTagIDs: document.deletedTagIDs
        )
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
