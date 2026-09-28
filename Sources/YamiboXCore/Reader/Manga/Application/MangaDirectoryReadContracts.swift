import Foundation

/// Resolves thread ownership in batches. Missing threads are omitted; read
/// failures must throw rather than masquerade as an empty result.
public protocol MangaDirectoryBatchReading: Sendable {
    /// Implementations must batch ownership lookup and reuse each distinct
    /// directory within the read. Do not fall back to one lookup per thread.
    func directories(containingTIDs tids: [String]) async throws -> [String: MangaDirectory]
}

public protocol MangaDirectoryReading: MangaDirectoryBatchReading {
    func directory(id: MangaDirectoryID) async throws -> MangaDirectory?
    func directory(named name: String) async throws -> MangaDirectory?
    func directory(containingTID tid: String) async throws -> MangaDirectory?
}

/// Per-instance invalidations after committed directory changes. Each
/// subscriber receives its own stream; signals may coalesce and require reload.
public protocol MangaDirectoryChangeObserving: Sendable {
    /// Stable, nonempty identity included in every emitted invalidation.
    nonisolated var changeID: String { get }
    /// Register before returning so a subsequent commit cannot be missed.
    /// Implementations must explicitly provide observation, never a silent sink.
    nonisolated func changes() -> AsyncStream<String>
}
