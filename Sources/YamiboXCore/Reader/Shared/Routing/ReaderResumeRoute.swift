import Foundation

public enum ReaderResumeRoute: Codable, Hashable, Sendable {
    case novel(NovelLaunchContext)
    case manga(MangaLaunchContext)

    private enum CodingKeys: String, CodingKey {
        case kind
        case novelContext
        case mangaContext
    }

    private enum Kind: String, Codable {
        case novel
        case manga
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .novel(context):
            try container.encode(Kind.novel, forKey: .kind)
            try container.encode(context, forKey: .novelContext)
        case let .manga(context):
            try container.encode(Kind.manga, forKey: .kind)
            try container.encode(context, forKey: .mangaContext)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .novel:
            self = .novel(try container.decode(NovelLaunchContext.self, forKey: .novelContext))
        case .manga:
            self = .manga(try container.decode(MangaLaunchContext.self, forKey: .mangaContext))
        }
    }
}
