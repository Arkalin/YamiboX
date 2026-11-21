import Foundation

enum BrowsingHistorySyncMergeV1 {
    static let maximumRecords = 2000

    static func merge(
        _ local: SyncRecordSnapshot<BrowsingHistorySyncRecord>,
        _ remote: SyncRecordSnapshot<BrowsingHistorySyncRecord>? = nil
    ) throws -> SyncRecordSnapshot<BrowsingHistorySyncRecord> {
        let deletions = local.deletions.merging(remote?.deletions ?? .init())
        var byID: [String: BrowsingHistorySyncRecord] = [:]
        for record in local.records + (remote?.records ?? []) {
            if let existing = byID[record.id] {
                if existing.lastVisitTime > record.lastVisitTime { continue }
                if existing.lastVisitTime == record.lastVisitTime,
                   try SyncContentFingerprint.make(existing) >= SyncContentFingerprint.make(record) { continue }
            }
            byID[record.id] = record
        }
        let records = Array(byID.values.filter {
            !deletions.containsDeletion(of: $0.id, updatedAt: $0.lastVisitTime)
                && !deletions.containsDeletion(of: $0.target.id, updatedAt: $0.lastVisitTime)
        }.sorted {
            $0.lastVisitTime == $1.lastVisitTime ? $0.id < $1.id : $0.lastVisitTime > $1.lastVisitTime
        }.prefix(maximumRecords))
        return SyncRecordSnapshot(records: records, deletions: deletions)
    }
}
