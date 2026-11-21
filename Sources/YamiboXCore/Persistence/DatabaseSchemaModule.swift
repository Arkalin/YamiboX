import Foundation
@preconcurrency import GRDB

protocol DatabaseSchemaModule: Sendable {
    static func registerMigrations(in migrator: inout DatabaseMigrator)

    static func erase(in db: Database) throws
}
