import Foundation
import Nuke

/// Nuke's disk cache only schedules its own sweep during initialization.
/// Coalesce online image writes into bounded, off-main maintenance windows.
final class YamiboMaintainedImageDataCache: DataCaching, @unchecked Sendable {
    private struct PendingMaintenance {
        let id: UUID
        let work: DispatchWorkItem
    }

    private let cache: DataCache
    private let queue = DispatchQueue(label: "com.arkalin.YamiboX.ImageCacheMaintenance", qos: .utility)
    private let delay: DispatchTimeInterval
    // All mutable state, including scheduling and cache mutation order, is locked.
    private let lock = NSLock()
    private var writeRevision: UInt64 = 0
    private var pending: PendingMaintenance?

    init(cache: DataCache, maintenanceDelay: DispatchTimeInterval = .seconds(30)) {
        self.cache = cache
        delay = maintenanceDelay
        // A recent Nuke sweep stamp can skip startup cleanup even when the
        // previous session subsequently exceeded its budget. Cover cache hits too.
        lock.withLock { scheduleMaintenanceIfNeeded() }
    }

    deinit { pending?.work.cancel() }

    func cachedData(for key: String) -> Data? { cache.cachedData(for: key) }
    func containsData(for key: String) -> Bool { cache.containsData(for: key) }

    func storeData(_ data: Data, for key: String) {
        lock.withLock {
            cache.storeData(data, for: key)
            writeRevision &+= 1
            scheduleMaintenanceIfNeeded()
        }
    }

    func removeData(for key: String) {
        lock.withLock { cache.removeData(for: key) }
    }

    func removeAll() {
        lock.withLock {
            cache.removeAll()
            pending?.work.cancel()
            pending = nil
        }
    }

    /// Called only with the lock held. A running window still occupies `pending`.
    private func scheduleMaintenanceIfNeeded() {
        guard pending == nil else { return }
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in self?.maintain(id: id) }
        pending = PendingMaintenance(id: id, work: work)
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func maintain(id: UUID) {
        guard let revision = lock.withLock({ pending?.id == id ? writeRevision : nil }) else { return }
        // A separate queue is required: both operations synchronously enter
        // Nuke's write queue. Flush staging before applying its existing LRU.
        cache.flush()
        if lock.withLock({ pending?.id == id }) { cache.sweep() }
        lock.withLock {
            guard pending?.id == id else { return }
            pending = nil
            // Writes arriving during IO may not be in the flushed snapshot.
            // Schedule one more window, never an idle repeating timer.
            if writeRevision != revision { scheduleMaintenanceIfNeeded() }
        }
    }
}
