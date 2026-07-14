import Foundation
@preconcurrency import GRDB

/// Contributed by each feature that owns tables in the shared `yamibox.sqlite` database.
///
/// `YamiboDatabase` owns the pool; each module owns its tables: it registers its own
/// migrations and knows how to erase its own rows (restoring required seed data).
protocol DatabaseSchemaModule: Sendable {
    /// Registers the migrations that create and evolve this module's tables.
    static func registerMigrations(in migrator: inout DatabaseMigrator)

    /// Deletes every row owned by this module and restores required seed data.
    static func erase(in db: Database) throws
}
