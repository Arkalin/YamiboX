import Foundation

/// A run-local index of the same three-way merge used for the eventual commit.
/// The store transfers this reference exclusively into one database read closure;
/// no task mutates it while it is retained on the actor or used by another read.
final class FavoriteUpdateNotificationBadge: @unchecked Sendable {
    let runID: String
    let revision: String
    private(set) var sequence: UInt64
    private(set) var unreadCount = 0

    private var rawRunByID: [String: FavoriteUpdateEvent] = [:]
    private var canonicalRunByID: [String: FavoriteUpdateEvent] = [:]
    private var undismissedIDsByRawTarget: [FavoriteUpdateTargetKey: Set<String>] = [:]
    private var storedByID: [String: FavoriteUpdateEvent] = [:]
    private var candidatesByID: [String: FavoriteUpdateEvent] = [:]
    private var candidateIDsByTarget: [FavoriteUpdateTargetKey: Set<String>] = [:]
    private var newestByTarget: [FavoriteUpdateTargetKey: FavoriteUpdateEvent] = [:]

    init?(
        runID: String, sequence: UInt64, revision: String,
        runEvents: [FavoriteUpdateEvent], storedEvents: [FavoriteUpdateEvent],
        canonicalize: (FavoriteUpdateEvent) throws -> FavoriteUpdateEvent
    ) rethrows {
        self.runID = runID
        self.sequence = sequence
        self.revision = revision
        for event in storedEvents { storedByID[event.id] = event }
        for event in runEvents {
            // Ordinary engine detections have unique UUIDs. Preserve the full
            // merge fallback for custom callers with duplicate run IDs.
            guard rawRunByID[event.id] == nil else { return nil }
            rawRunByID[event.id] = event
            canonicalRunByID[event.id] = try canonicalize(event)
            if event.dismissedAt == nil {
                undismissedIDsByRawTarget[event.target, default: []].insert(event.id)
            }
        }
        for id in Set(storedByID.keys).union(rawRunByID.keys) {
            guard let event = candidate(id: id) else { continue }
            candidatesByID[id] = event
            candidateIDsByTarget[event.target, default: []].insert(id)
            if let current = newestByTarget[event.target], Self.isNewer(current, than: event) { continue }
            newestByTarget[event.target] = event
        }
        unreadCount = newestByTarget.values.filter(Self.isUnread).count
    }

    /// The engine removes undismissed events for the raw target before it
    /// appends a new detection. Keep that raw identity separate from the
    /// canonical identity used for store/run conflict resolution.
    func replaceUndismissed(
        with event: FavoriteUpdateEvent, runEventCount: Int, sequence: UInt64,
        canonicalize: (FavoriteUpdateEvent) throws -> FavoriteUpdateEvent
    ) rethrows -> Bool {
        let removed = undismissedIDsByRawTarget[event.target] ?? []
        guard rawRunByID.count - removed.count + 1 == runEventCount,
              rawRunByID[event.id] == nil || removed.contains(event.id) else { return false }
        let canonical = try canonicalize(event)
        var affectedTargets: Set<FavoriteUpdateTargetKey> = []

        func updateCandidate(_ id: String) {
            if let previous = candidatesByID.removeValue(forKey: id) {
                affectedTargets.insert(previous.target)
                candidateIDsByTarget[previous.target]?.remove(id)
            }
            if let updated = candidate(id: id) {
                affectedTargets.insert(updated.target)
                candidatesByID[id] = updated
                candidateIDsByTarget[updated.target, default: []].insert(id)
            }
        }

        for id in removed {
            rawRunByID[id] = nil
            canonicalRunByID[id] = nil
            // Removing a run copy may reveal a concurrently stored copy of
            // that same ID; the authoritative merge does not discard it.
            updateCandidate(id)
        }
        undismissedIDsByRawTarget[event.target] = nil
        rawRunByID[event.id] = event
        canonicalRunByID[event.id] = canonical
        if event.dismissedAt == nil { undismissedIDsByRawTarget[event.target] = [event.id] }
        updateCandidate(event.id)

        var addedNewest: [FavoriteUpdateTargetKey: FavoriteUpdateEvent] = [:]
        for id in removed.union([event.id]) {
            guard let added = candidatesByID[id] else { continue }
            if let current = addedNewest[added.target], Self.isNewer(current, than: added) { continue }
            addedNewest[added.target] = added
        }
        for target in affectedTargets {
            let previous = newestByTarget[target]
            if previous.map(Self.isUnread) == true { unreadCount -= 1 }
            let added = addedNewest[target]
            let next: FavoriteUpdateEvent?
            if let previous, let retained = candidatesByID[previous.id], retained.target == target,
               retained.detectedAt == previous.detectedAt {
                next = added.map { Self.isNewer($0, than: retained) ? $0 : retained } ?? retained
            } else if let added, previous == nil || !Self.isNewer(previous!, than: added) {
                next = added
            } else {
                // Clock reversal or removal of the newest detection can expose
                // older same-target history. Scan only that target's bucket.
                next = candidateIDsByTarget[target]?.compactMap { candidatesByID[$0] }
                    .max { Self.isNewer($1, than: $0) }
            }
            newestByTarget[target] = next
            if next.map(Self.isUnread) == true { unreadCount += 1 }
            if candidateIDsByTarget[target]?.isEmpty == true { candidateIDsByTarget[target] = nil }
        }
        self.sequence = sequence
        return true
    }

    private func candidate(id: String) -> FavoriteUpdateEvent? {
        guard var event = canonicalRunByID[id] else { return storedByID[id] }
        if let stored = storedByID[id] {
            event.readAt = stored.readAt ?? event.readAt
            event.dismissedAt = stored.dismissedAt ?? event.dismissedAt
        }
        return event
    }

    private static func isNewer(_ lhs: FavoriteUpdateEvent, than rhs: FavoriteUpdateEvent) -> Bool {
        (lhs.detectedAt, lhs.id) > (rhs.detectedAt, rhs.id)
    }

    private static func isUnread(_ event: FavoriteUpdateEvent) -> Bool {
        event.readAt == nil && event.dismissedAt == nil
    }
}
