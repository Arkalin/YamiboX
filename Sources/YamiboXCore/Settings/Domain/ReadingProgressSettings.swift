import Foundation

public struct ReadingProgressSettings: Codable, Hashable, Sendable {
    public var savesNormalThreadProgress: Bool

    public init(savesNormalThreadProgress: Bool = false) {
        self.savesNormalThreadProgress = savesNormalThreadProgress
    }

    private enum CodingKeys: String, CodingKey {
        case savesNormalThreadProgress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            savesNormalThreadProgress: try container.decodeIfPresent(Bool.self, forKey: .savesNormalThreadProgress) ?? false
        )
    }
}
