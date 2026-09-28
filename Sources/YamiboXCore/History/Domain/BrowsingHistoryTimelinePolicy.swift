/// Runtime timeline ordering and retention, shared by reconciliation and storage.
/// Historical migrations continue to use their frozen merge rules directly.
enum BrowsingHistoryTimelinePolicy {
    static let maximumRecords = BrowsingHistorySyncMergeV1.maximumRecords

    static func newestFirst(_ lhs: BrowsingHistoryEntry, _ rhs: BrowsingHistoryEntry) -> Bool {
        lhs.lastVisitTime == rhs.lastVisitTime ? lhs.id < rhs.id : lhs.lastVisitTime > rhs.lastVisitTime
    }
}
