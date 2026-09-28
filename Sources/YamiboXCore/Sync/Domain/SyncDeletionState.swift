import Foundation

/// Deletion history is independent of live rows, including on a device that
/// has never seen the deleted content. It must survive every sync round.
struct SyncDeletionState: Codable, Equatable, Sendable {
    var clearedAt: Date?
    var tombstones: [String: Date] = [:]

    func containsDeletion(of id: String, updatedAt: Date) -> Bool {
        if let clearedAt, updatedAt <= clearedAt { return true }
        return tombstones[id].map { updatedAt <= $0 } ?? false
    }

    mutating func recordDeletion(of id: String, at date: Date) {
        tombstones[id] = max(tombstones[id] ?? date, date)
    }

    mutating func clear(at date: Date) {
        clearedAt = max(clearedAt ?? date, date)
    }

    func merging(_ other: Self) -> Self {
        var result = self
        if let date = other.clearedAt { result.clear(at: date) }
        for (id, date) in other.tombstones { result.recordDeletion(of: id, at: date) }
        return result
    }

    /// Shared last-deletion-wins rule used by the dataset-specific mergers.
    static func mergingTombstones(_ lhs: [String: Date], _ rhs: [String: Date]) -> [String: Date] {
        var result = lhs
        for (key, value) in rhs {
            if let existing = result[key], existing >= value {
                continue
            }
            result[key] = value
        }
        return result
    }
}

struct SyncRecordSnapshot<Record: Sendable>: Sendable {
    var records: [Record]
    var deletions: SyncDeletionState = .init()
}

extension SyncRecordSnapshot: Encodable where Record: Encodable {}
extension SyncRecordSnapshot: Equatable where Record: Equatable {}
