import Foundation

/// Reading-progress-only target kind (`ReadingProgressRecord.contentTarget`).
/// Favorites no longer use this type at all — see `FavoriteItemTarget` below,
/// which is the favorites-side equivalent and deliberately cannot represent
/// `.mangaTitle` (2026-07-08 smart-comic-mode decision #9's second
/// correction: a compiler-enforced split, not a dead switch branch).
public enum FavoriteContentTargetKind: String, Codable, CaseIterable, Sendable {
    case normalThread
    case novelThread
    case mangaTitle
    /// Per-thread manga reading progress, written alongside (mode on) or
    /// instead of (mode off) the directory-level `.mangaTitle` record. See
    /// smart-comic-mode design decision #15. The full dual-write/read
    /// mode-dependent logic is implemented in a later phase; this phase only
    /// adds the case and its column mapping.
    case mangaThread
}

/// Reading-progress-only target type (`ReadingProgressRecord.contentTarget`).
/// Kept exactly as it was before smart-comic-mode except for the new
/// `.mangaThread` case (decision #15) — the favorites side now uses the
/// separate `FavoriteItemTarget` type instead of this one (decision #9's
/// second correction).
public enum FavoriteContentTarget: Codable, Hashable, Identifiable, Sendable {
    case normalThread(threadID: String)
    case novelThread(threadID: String)
    case mangaTitle(mangaID: String, cleanBookName: String)
    /// This thread's own manga reading progress, independent of the
    /// directory-level `.mangaTitle` record. Deliberately uses the same id
    /// format (`"manga-thread:\(threadID)"`) as the favorites-side
    /// `FavoriteItemTarget.mangaThread` so a closed-board single-thread
    /// favorite can match its progress record by direct id lookup without a
    /// cleanBookName fallback (smart-comic-mode design decision #15).
    case mangaThread(threadID: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID
        case mangaID
        case cleanBookName
    }

    public var id: String {
        switch self {
        case let .normalThread(threadID):
            "thread:normal:\(threadID)"
        case let .novelThread(threadID):
            "thread:novel:\(threadID)"
        case let .mangaTitle(mangaID, _):
            "manga-title:\(mangaID)"
        case let .mangaThread(threadID):
            "manga-thread:\(threadID)"
        }
    }

    public var kind: FavoriteContentTargetKind {
        switch self {
        case .normalThread:
            .normalThread
        case .novelThread:
            .novelThread
        case .mangaTitle:
            .mangaTitle
        case .mangaThread:
            .mangaThread
        }
    }

    public var mangaID: String? {
        guard case let .mangaTitle(mangaID, _) = self else { return nil }
        return mangaID
    }

    public var mangaCleanBookName: String? {
        guard case let .mangaTitle(_, cleanBookName) = self else { return nil }
        return cleanBookName
    }

    public var threadID: String? {
        switch self {
        case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
            threadID
        case .mangaTitle:
            nil
        }
    }

    public init(kind: FavoriteContentTargetKind, threadID: String) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "FavoriteContentTarget requires a Yamibo thread tid")
        switch kind {
        case .normalThread:
            self = .normalThread(threadID: normalizedThreadID)
        case .novelThread:
            self = .novelThread(threadID: normalizedThreadID)
        case .mangaTitle:
            self = .mangaTitle(mangaID: normalizedThreadID, cleanBookName: normalizedThreadID)
        case .mangaThread:
            self = .mangaThread(threadID: normalizedThreadID)
        }
    }

    public init(mangaCleanBookName: String) {
        let normalizedName = mangaCleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        self = .mangaTitle(mangaID: normalizedName, cleanBookName: normalizedName)
    }

    public init(mangaID: String, mangaCleanBookName: String) {
        let normalizedName = mangaCleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = mangaID.trimmingCharacters(in: .whitespacesAndNewlines)
        self = .mangaTitle(
            mangaID: normalizedID.isEmpty ? normalizedName : normalizedID,
            cleanBookName: normalizedName
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(FavoriteContentTargetKind.self, forKey: .kind)
        switch kind {
        case .normalThread:
            self = .normalThread(threadID: try Self.decodeThreadID(from: container))
        case .novelThread:
            self = .novelThread(threadID: try Self.decodeThreadID(from: container))
        case .mangaTitle:
            let cleanBookName = try container.decode(String.self, forKey: .cleanBookName)
            self = .mangaTitle(
                mangaID: try container.decodeIfPresent(String.self, forKey: .mangaID) ?? cleanBookName,
                cleanBookName: cleanBookName
            )
        case .mangaThread:
            self = .mangaThread(threadID: try Self.decodeThreadID(from: container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
            try container.encode(threadID, forKey: .threadID)
        case let .mangaTitle(mangaID, cleanBookName):
            try container.encode(mangaID, forKey: .mangaID)
            try container.encode(cleanBookName, forKey: .cleanBookName)
        }
    }

    public func renamedMangaTitle(to cleanBookName: String) -> FavoriteContentTarget {
        guard case let .mangaTitle(mangaID, _) = self else { return self }
        return FavoriteContentTarget(mangaID: mangaID, mangaCleanBookName: cleanBookName)
    }

    private static func decodeThreadID(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        if let threadID = try container.decodeIfPresent(String.self, forKey: .threadID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !threadID.isEmpty {
            return threadID
        }
        throw DecodingError.keyNotFound(
            CodingKeys.threadID,
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "FavoriteContentTarget requires threadID")
        )
    }
}
