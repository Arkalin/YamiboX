import Foundation

public enum FavoriteItemTargetKind: String, Codable, CaseIterable, Sendable {
    case normalThread
    case novelThread
    case mangaThread
}

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
