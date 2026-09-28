import Foundation
@preconcurrency import GRDB

/// Owns only the write boundary. Stores retain their SQL, merge rules and
/// notification conditions; failed transactions never publish an invalidation.
enum StoreWriteTransaction {
    static nonisolated(nonsending) func perform<Value: Sendable>(
        in database: DatabasePool,
        notifying broadcaster: StoreChangeBroadcaster,
        shouldNotify: @Sendable (Value) -> Bool = { _ in true },
        _ updates: @escaping @Sendable (Database) throws -> Value
    ) async throws -> Value {
        do {
            let value = try await database.write(updates)
            if shouldNotify(value) { broadcaster.post() }
            return value
        } catch let error as YamiboError {
            throw error
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }
}
