import Foundation

/// Shared deletion rules, independent of each dataset's conflict resolution,
/// wire format and position deduplication. Historical migrations do not use this.
enum SyncSoftDeletionRules {
    static func tombstones<Records: Sequence>(
        in records: Records,
        id: KeyPath<Records.Element, String>,
        deletedAt: KeyPath<Records.Element, Date?>
    ) -> [String: Date] {
        Dictionary(records.compactMap { record in
            record[keyPath: deletedAt].map { (record[keyPath: id], $0) }
        }, uniquingKeysWith: max)
    }

    static func applying<Records: Sequence>(
        _ tombstones: [String: Date],
        to records: Records,
        id: KeyPath<Records.Element, String>,
        updatedAt: WritableKeyPath<Records.Element, Date>,
        deletedAt: WritableKeyPath<Records.Element, Date?>
    ) -> [Records.Element] {
        records.map { record in
            var resolved = record
            if let deletion = tombstones[record[keyPath: id]], deletion >= record[keyPath: updatedAt] {
                resolved[keyPath: deletedAt] = deletion
                resolved[keyPath: updatedAt] = max(record[keyPath: updatedAt], deletion)
            } else {
                resolved[keyPath: deletedAt] = nil
            }
            return resolved
        }
    }
}
