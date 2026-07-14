import Foundation

struct NovelReaderContent: Codable, Hashable, Sendable {
    var data: String
    var type: ContentType
    var chapterTitle: String?

    init(data: String, type: ContentType, chapterTitle: String? = nil) {
        self.data = data
        self.type = type
        self.chapterTitle = chapterTitle
    }
}

enum ContentType: String, Codable, Sendable {
    case image
    case text
}
