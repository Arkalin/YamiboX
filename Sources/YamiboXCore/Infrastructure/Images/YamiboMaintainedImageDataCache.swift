import Foundation
import Nuke

/// Coalesces writes into off-main maintenance windows with a bounded cover
/// preference. Nuke owns staging and IO; this wrapper owns eviction policy.
final class YamiboMaintainedImageDataCache: DataCaching, @unchecked Sendable {
    typealias CoverCacheKeys = @Sendable () async throws -> Set<String>
    static let defaultCoverProtectionLimitBytes = 256 * 1024 * 1024

    private struct PendingMaintenance {
        let id: UUID
        let work: DispatchWorkItem
    }

    private struct Entry {
        let url: URL
        let allocatedBytes: Int
        let accessedAt: Date
    }

    private enum InventoryError: Error {
        case incompleteEntry
    }

    private let cache: DataCache
    private let queue = DispatchQueue(label: "com.arkalin.YamiboX.ImageCacheMaintenance", qos: .utility)
    private let delay: DispatchTimeInterval
    private let coverCacheKeys: CoverCacheKeys
    // All mutable state, including scheduling and cache mutation order, is locked.
    private let lock = NSLock()
    private var writeRevision: UInt64 = 0
    private var pending: PendingMaintenance?

    init(
        cache: DataCache,
        maintenanceDelay: DispatchTimeInterval = .seconds(30),
        coverCacheKeys: @escaping CoverCacheKeys = { [] }
    ) {
        self.cache = cache
        delay = maintenanceDelay
        self.coverCacheKeys = coverCacheKeys
        // Its startup sweep must not bypass the bounded cover preference.
        cache.isSweepEnabled = false
        // Include cache-hit-only sessions even if Nuke's last sweep was recent.
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
            pending?.work.cancel()
            pending = nil
            cache.removeAll()
        }
    }

    /// Called only with the lock held. A running window still occupies `pending`.
    private func scheduleMaintenanceIfNeeded() {
        guard pending == nil else { return }
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in
            Task { await self?.maintain(id: id) }
        }
        pending = PendingMaintenance(id: id, work: work)
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func maintain(id: UUID) async {
        guard let revision = lock.withLock({ pending?.id == id ? writeRevision : nil }) else { return }
        defer { finishMaintenance(id: id, revision: revision) }
        do {
            let keys = try await coverCacheKeys()
            guard isCurrentMaintenance(id) else { return }
            // Never call flush from Nuke's queue: it synchronously enters it.
            cache.flush()
            guard isCurrentMaintenance(id) else { return }
            try cache.queue.sync {
                guard isCurrentMaintenance(id) else { return }
                try sweep(id: id, coverKeys: keys)
            }
        } catch {
            guard isCurrentMaintenance(id) else { return }
            YamiboLog.persistence.error("Image cache maintenance skipped: \(error). Retrying only after new writes or next launch.")
        }
    }

    private func isCurrentMaintenance(_ id: UUID) -> Bool {
        lock.withLock { pending?.id == id }
    }

    private func finishMaintenance(id: UUID, revision: UInt64) {
        lock.withLock {
            guard pending?.id == id else { return }
            pending = nil
            // Writes arriving during IO may not be in the flushed snapshot.
            // Schedule one more window, never an idle repeating timer.
            if writeRevision != revision { scheduleMaintenanceIfNeeded() }
        }
    }

    /// Runs on Nuke's write queue so files cannot be replaced during eviction.
    private func sweep(id: UUID, coverKeys: Set<String>) throws {
        let entries = try inventory().sorted {
            if $0.accessedAt != $1.accessedAt { return $0.accessedAt > $1.accessedAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        var remainingBytes = entries.reduce(0) { $0 + $1.allocatedBytes }
        guard remainingBytes > cache.sizeLimit, isCurrentMaintenance(id) else { return }

        let targetBytes = Int(Double(cache.sizeLimit) * 0.7)
        let protectionLimit = min(Self.defaultCoverProtectionLimitBytes, targetBytes)
        let coverFilenames = Set(coverKeys.compactMap { cache.filename(for: $0) })
        var protectedFilenames: Set<String> = []
        var protectedBytes = 0
        for entry in entries where coverFilenames.contains(entry.url.lastPathComponent) {
            guard entry.allocatedBytes <= protectionLimit - protectedBytes else { continue }
            protectedFilenames.insert(entry.url.lastPathComponent)
            protectedBytes += entry.allocatedBytes
        }

        var removedCount = 0
        for entry in entries.reversed() {
            guard remainingBytes > targetBytes else { break }
            guard !protectedFilenames.contains(entry.url.lastPathComponent) else { continue }
            // A queue alone does not invalidate a sweep after removeAll stages
            // a clear. Admission and deletion are atomic with that operation.
            let isCurrent = lock.withLock {
                guard pending?.id == id else { return false }
                do {
                    try FileManager.default.removeItem(at: entry.url)
                    remainingBytes -= entry.allocatedBytes
                    removedCount += 1
                } catch {
                    YamiboLog.persistence.error("Image cache entry deletion failed: \(error)")
                }
                return true
            }
            guard isCurrent else { return }
        }

        guard isCurrentMaintenance(id) else { return }
        // Recount rather than reporting an optimistic total after IO failures.
        remainingBytes = try inventory().reduce(0) { $0 + $1.allocatedBytes }
        guard isCurrentMaintenance(id) else { return }
        if remainingBytes > targetBytes {
            YamiboLog.persistence.warning("Image cache eviction incomplete: allocated=\(remainingBytes) target=\(targetBytes) protected=\(protectedBytes) removed=\(removedCount). No immediate retry.")
        } else {
            YamiboLog.persistence.info("Image cache eviction completed: allocated=\(remainingBytes) target=\(targetBytes) protected=\(protectedBytes) removed=\(removedCount)")
        }
    }

    /// Never silently omit an unreadable entry and evict from a partial total.
    private func inventory() throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentAccessDateKey, .totalFileAllocatedSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: cache.path,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        )
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  let allocatedBytes = values.totalFileAllocatedSize,
                  allocatedBytes >= 0 else { throw InventoryError.incompleteEntry }
            return Entry(url: url, allocatedBytes: allocatedBytes, accessedAt: values.contentAccessDate ?? .distantPast)
        }
    }
}
