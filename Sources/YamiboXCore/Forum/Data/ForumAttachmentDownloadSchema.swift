import Foundation
@preconcurrency import GRDB

enum ForumAttachmentDownloadSchema {
    static let tables = ["download_attachment_requests", "download_attachment_entries"]

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("downloads.v2.attachments") { db in
            try db.create(table: "download_attachment_requests") { table in
                table.column("reader_kind", .text).notNull()
                table.column("owner_name", .text).notNull()
                table.column("tid", .text).notNull()
                table.column("request_json", .blob).notNull()
                table.primaryKey(["reader_kind", "owner_name", "tid"])
                table.foreignKey(["reader_kind", "owner_name", "tid"], references: "download_works",
                                 columns: ["reader_kind", "owner_name", "tid"], onDelete: .cascade)
            }
            try db.create(table: "download_attachment_entries") { table in
                table.column("entry_key", .text).primaryKey()
                table.column("owner_name", .text).notNull()
                table.column("owner_title", .text).notNull()
                table.column("file_name", .text).notNull()
                table.column("directory_name", .text).notNull()
                table.column("byte_count", .integer).notNull()
                table.column("updated_at", .double).notNull()
            }
        }
    }
}
