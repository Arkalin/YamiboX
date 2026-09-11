import Foundation
@preconcurrency import GRDB

enum ForumComposerDraftDatabaseSchema: DatabaseSchemaModule {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("forum.composer-drafts.v1") { db in
            try db.create(table: "forum_composer_draft_generation") { table in
                table.column("id", .integer).primaryKey()
                table.column("generation", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO forum_composer_draft_generation (id, generation) VALUES (1, ?)", arguments: [UUID().uuidString])
            try db.create(table: "forum_composer_drafts") { table in
                table.column("id", .text).primaryKey()
                table.column("account_uid", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("updated_at", .double).notNull()
                table.column("deleted", .boolean).notNull().defaults(to: false)
                table.column("payload", .blob)
            }
            try db.create(index: "forum_composer_drafts_account", on: "forum_composer_drafts", columns: ["account_uid", "deleted", "updated_at"])
            try db.create(table: "forum_composer_draft_resources") { table in
                table.column("id", .text).primaryKey()
                table.column("draft_id", .text).notNull()
                table.column("account_uid", .text).notNull()
                table.column("name", .text).notNull()
            }
            try db.create(index: "forum_composer_draft_resources_owner", on: "forum_composer_draft_resources", columns: ["draft_id", "account_uid"])
        }
    }

    static func erase(in db: Database) throws {
        try db.execute(sql: "DELETE FROM forum_composer_drafts")
        try db.execute(sql: "DELETE FROM forum_composer_draft_resources")
        try db.execute(sql: "UPDATE forum_composer_draft_generation SET generation = ? WHERE id = 1", arguments: [UUID().uuidString])
    }
}
