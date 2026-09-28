import Foundation
@preconcurrency import GRDB

extension SyncDeletionState {
    // Table names below are module-owned constants, never external input.
    static func createTable(_ table: String, in db: Database) throws {
        try db.create(table: table) { definition in
            definition.column("id", .integer).primaryKey().check { $0 == 1 }
            definition.column("state", .blob).notNull()
        }
    }

    static func load(from table: String, in db: Database) throws -> Self {
        guard let data = try Data.fetchOne(db, sql: "SELECT state FROM \(table) WHERE id = 1") else {
            return Self()
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save(to table: String, in db: Database) throws {
        let data = try JSONEncoder().encode(self)
        try db.execute(sql: "INSERT OR REPLACE INTO \(table) (id, state) VALUES (1, ?)", arguments: [data])
    }

    static func migrateSoftDeletions(from source: String, to table: String, in db: Database) throws {
        try createTable(table, in: db)
        var state = Self()
        for row in try Row.fetchAll(db, sql: "SELECT id, deleted_at FROM \(source) WHERE deleted_at IS NOT NULL") {
            state.recordDeletion(of: row["id"], at: Date(timeIntervalSince1970: row["deleted_at"]))
        }
        try state.save(to: table, in: db)
    }
}
