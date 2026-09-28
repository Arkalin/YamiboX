import Foundation

public struct MangaDirectoryEditDraft: Hashable, Sendable {
    public var cleanBookName: String
    public var primaryKeyword: String
    public var secondaryKeyword: String

    public init(
        cleanBookName: String,
        primaryKeyword: String,
        secondaryKeyword: String
    ) {
        self.cleanBookName = cleanBookName
        self.primaryKeyword = primaryKeyword
        self.secondaryKeyword = secondaryKeyword
    }
}
