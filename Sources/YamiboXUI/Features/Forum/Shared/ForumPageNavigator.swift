import Foundation

/// In-page navigation history for forum list screens (board, search, ...).
///
/// Owns the snapshot stack that lets a screen return to the exact state it
/// showed before a page jump. The owning view model only supplies two
/// closures: how to capture its current state and how to restore a captured
/// state. Everything else — the stack, popping, discarding failed jumps —
/// stays inside this type.
@MainActor
final class ForumPageNavigator<Snapshot> {
    private let capture: () -> Snapshot
    private let restore: (Snapshot) -> Void
    private var history: [Snapshot] = []

    init(
        capture: @escaping () -> Snapshot,
        restore: @escaping (Snapshot) -> Void
    ) {
        self.capture = capture
        self.restore = restore
    }

    var canRestorePreviousPage: Bool {
        !history.isEmpty
    }

    /// Records the current state before navigating to another page.
    func recordCurrentPage() {
        history.append(capture())
    }

    /// Drops the most recent record without restoring it. Call when a page
    /// jump fails and the screen should stay on the error state instead of
    /// keeping the failed jump in history.
    func discardLastRecord() {
        _ = history.popLast()
    }

    /// Restores the most recently recorded state. Returns false when there is
    /// no history to restore.
    @discardableResult
    func restorePreviousPage() -> Bool {
        guard let snapshot = history.popLast() else { return false }
        restore(snapshot)
        return true
    }

    /// Clears all history, e.g. when a filter change starts a fresh listing.
    func reset() {
        history.removeAll()
    }
}
