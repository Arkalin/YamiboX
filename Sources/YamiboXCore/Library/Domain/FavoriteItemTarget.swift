import Foundation

/// Favorites-only target kind (`FavoriteItem.target`). Physically cannot
/// represent the reading-progress-side `.mangaTitle` merged-directory
/// identity — see `FavoriteItemTarget`.
public enum FavoriteItemTargetKind: String, Codable, CaseIterable, Sendable {
    case normalThread
    case novelThread
    case mangaThread
}

/// Favorites-only target type. Introduced by smart-comic-mode design decision
/// #9's second correction: favorites and reading progress used to share
/// `FavoriteContentTarget`, but the user explicitly rejected keeping a dead
/// `.mangaTitle` fallback branch in favorites' exhaustive switches just to
/// satisfy the compiler. This type has exactly three cases — every switch
/// over it is exhaustive without a `.mangaTitle` option, so a favorite simply
/// cannot be constructed with the old merged-directory identity.
///
/// `.mangaThread(threadID:)` is a *different* case from the reading-progress
/// side's `FavoriteContentTarget.mangaThread(threadID:)` — same name, two
/// unrelated enums, one per consumer (`FavoriteItem.target` vs
/// `ReadingProgressRecord.contentTarget`). Their `.id` strings are
/// deliberately formatted identically (`"manga-thread:\(threadID)"`) so a
/// favorite and its own per-thread reading progress line up by direct id
/// lookup (design decision #15).
public enum FavoriteItemTarget: Codable, Hashable, Identifiable, Sendable {
    case normalThread(threadID: String)
    case novelThread(threadID: String)
    case mangaThread(threadID: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID
    }

    public var id: String {
        switch self {
        case let .normalThread(threadID):
            "thread:normal:\(threadID)"
        case let .novelThread(threadID):
            "thread:novel:\(threadID)"
        case let .mangaThread(threadID):
            "manga-thread:\(threadID)"
        }
    }

    public var kind: FavoriteItemTargetKind {
        switch self {
        case .normalThread:
            .normalThread
        case .novelThread:
            .novelThread
        case .mangaThread:
            .mangaThread
        }
    }

    /// Every case carries a real Yamibo thread tid — unlike the old shared
    /// `FavoriteContentTarget.mangaTitle`, there is no case here without one.
    /// Kept `String?` (rather than a non-optional `String`) purely to match
    /// the shape favorites-side call sites already expect from the shared
    /// type this replaces, minimizing churn at existing `guard let`/`?? `
    /// call sites.
    public var threadID: String? {
        switch self {
        case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
            threadID
        }
    }

    public init(kind: FavoriteItemTargetKind, threadID: String) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "FavoriteItemTarget requires a Yamibo thread tid")
        switch kind {
        case .normalThread:
            self = .normalThread(threadID: normalizedThreadID)
        case .novelThread:
            self = .novelThread(threadID: normalizedThreadID)
        case .mangaThread:
            self = .mangaThread(threadID: normalizedThreadID)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(FavoriteItemTargetKind.self, forKey: .kind)
        let threadID = try Self.decodeThreadID(from: container)
        switch kind {
        case .normalThread:
            self = .normalThread(threadID: threadID)
        case .novelThread:
            self = .novelThread(threadID: threadID)
        case .mangaThread:
            self = .mangaThread(threadID: threadID)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
            try container.encode(threadID, forKey: .threadID)
        }
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
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "FavoriteItemTarget requires threadID")
        )
    }
}
