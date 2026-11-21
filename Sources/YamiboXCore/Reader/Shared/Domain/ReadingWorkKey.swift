import Foundation

public enum ReadingWorkKind: String, Codable, Hashable, Sendable, CaseIterable {
    case novel
    case manga
}

public struct ReadingWorkKey: Codable, Hashable, Sendable {
    public var kind: ReadingWorkKind
    public var id: String

    public init(kind: ReadingWorkKind, id: String) {
        self.kind = kind
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func novel(threadID: String) -> ReadingWorkKey {
        ReadingWorkKey(kind: .novel, id: threadID)
    }

    public static func mangaTitle(directoryID: MangaDirectoryID) -> ReadingWorkKey {
        ReadingWorkKey(kind: .manga, id: directoryID.rawValue)
    }

}
