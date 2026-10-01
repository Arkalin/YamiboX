import Foundation
import os

/// Preserves the run's array order while replacing only a raw target's live
/// events. Removal versions retain the contents needed by an earlier lazy badge
/// snapshot, even if its database read finishes after a newer mutation.
final class FavoriteUpdateRunEventAccumulator: Sendable {
    struct Snapshot: Sendable {
        let count: Int
        let materialize: @Sendable () -> [FavoriteUpdateEvent]
    }

    private struct Slot {
        let event: FavoriteUpdateEvent
        let insertedAt: Int
        var removedAt: Int?
    }

    private struct State {
        var slots: [Slot]
        var undismissedSlots: [FavoriteUpdateTargetKey: [Int]] = [:]
        var count: Int
        var version = 0

        init(_ events: [FavoriteUpdateEvent]) {
            slots = events.map { Slot(event: $0, insertedAt: 0) }
            count = events.count
            for (index, event) in events.enumerated() where event.dismissedAt == nil {
                undismissedSlots[event.target, default: []].append(index)
            }
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ events: [FavoriteUpdateEvent] = []) {
        state = OSAllocatedUnfairLock(initialState: State(events))
    }

    var count: Int { state.withLock { $0.count } }

    func firstUndismissed(for target: FavoriteUpdateTargetKey) -> FavoriteUpdateEvent? {
        state.withLock { current in
            guard let index = current.undismissedSlots[target]?.first else { return nil }
            return current.slots[index].event
        }
    }

    func replaceUndismissed(with event: FavoriteUpdateEvent) {
        state.withLock { current in
            let removed = current.undismissedSlots.removeValue(forKey: event.target) ?? []
            current.version += 1
            for index in removed { current.slots[index].removedAt = current.version }
            current.count -= removed.count
            let index = current.slots.count
            current.slots.append(Slot(event: event, insertedAt: current.version))
            current.count += 1
            if event.dismissedAt == nil { current.undismissedSlots[event.target] = [index] }
        }
    }

    func materialize() -> [FavoriteUpdateEvent] {
        snapshot().materialize()
    }

    func snapshot() -> Snapshot {
        let (version, limit, count) = state.withLock { ($0.version, $0.slots.count, $0.count) }
        return Snapshot(count: count, materialize: { [self] in
            materialize(version: version, limit: limit, count: count)
        })
    }

    private func materialize(version: Int, limit: Int, count: Int) -> [FavoriteUpdateEvent] {
        state.withLock { current in
            var result: [FavoriteUpdateEvent] = []
            result.reserveCapacity(count)
            for slot in current.slots.prefix(limit)
            where slot.insertedAt <= version && (slot.removedAt == nil || slot.removedAt! > version) {
                result.append(slot.event)
            }
            return result
        }
    }
}
