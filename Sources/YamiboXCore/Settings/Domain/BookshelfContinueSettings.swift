import Foundation

public enum BookshelfContinueMode: String, Codable, Hashable, CaseIterable, Sendable {
    case separate
    case mixed
}

public struct BookshelfContinueSettings: Codable, Hashable, Sendable {
    public var mode: BookshelfContinueMode
    public private(set) var novelCount: Int
    public private(set) var mangaCount: Int
    public private(set) var mixedCount: Int

    public init(
        mode: BookshelfContinueMode = .separate,
        novelCount: Int = 1,
        mangaCount: Int = 1,
        mixedCount: Int = 2
    ) {
        self.mode = mode
        self.novelCount = min(2, max(0, novelCount))
        self.mangaCount = min(2, max(0, mangaCount))
        self.mixedCount = min(4, max(1, mixedCount))
        if self.novelCount + self.mangaCount == 0 {
            self.novelCount = 1
        }
    }

    public var novelCountRange: ClosedRange<Int> { (mangaCount == 0 ? 1 : 0)...2 }
    public var mangaCountRange: ClosedRange<Int> { (novelCount == 0 ? 1 : 0)...2 }

    public mutating func setNovelCount(_ count: Int) {
        novelCount = min(novelCountRange.upperBound, max(novelCountRange.lowerBound, count))
    }

    public mutating func setMangaCount(_ count: Int) {
        mangaCount = min(mangaCountRange.upperBound, max(mangaCountRange.lowerBound, count))
    }

    public mutating func setMixedCount(_ count: Int) {
        mixedCount = min(4, max(1, count))
    }

    private enum CodingKeys: String, CodingKey {
        case mode, novelCount, mangaCount, mixedCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(BookshelfContinueMode.self, forKey: .mode) ?? .separate,
            novelCount: try container.decodeIfPresent(Int.self, forKey: .novelCount) ?? 1,
            mangaCount: try container.decodeIfPresent(Int.self, forKey: .mangaCount) ?? 1,
            mixedCount: try container.decodeIfPresent(Int.self, forKey: .mixedCount) ?? 2
        )
    }
}
