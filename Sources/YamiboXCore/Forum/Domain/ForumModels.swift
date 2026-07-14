import Foundation

public struct ForumHomePage: Codable, Equatable, Sendable {
    public var categories: [ForumCategory]
    public var carouselItems: [ForumHomeCarouselItem]
    public var formHash: String?
    public var fetchedAt: Date

    public init(
        categories: [ForumCategory],
        carouselItems: [ForumHomeCarouselItem] = [],
        formHash: String? = nil,
        fetchedAt: Date = .now
    ) {
        self.categories = categories
        self.carouselItems = carouselItems
        self.formHash = formHash
        self.fetchedAt = fetchedAt
    }
}

public struct ForumCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var boards: [ForumBoardSummary]

    public init(id: String, title: String, boards: [ForumBoardSummary]) {
        self.id = id
        self.title = title
        self.boards = boards
    }
}

public struct ForumBoardSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var fid: String
    public var name: String
    public var detail: String?
    public var todayCount: Int?
    public var threadCount: Int?
    public var rank: Int?
    public var iconURL: URL?
    public var url: URL

    public var id: String { fid }

    public init(
        fid: String,
        name: String,
        detail: String? = nil,
        todayCount: Int? = nil,
        threadCount: Int? = nil,
        rank: Int? = nil,
        iconURL: URL? = nil,
        url: URL
    ) {
        self.fid = fid
        self.name = name
        self.detail = detail
        self.todayCount = todayCount
        self.threadCount = threadCount
        self.rank = rank
        self.iconURL = iconURL
        self.url = url
    }
}

public struct ForumHomeCarouselItem: Codable, Equatable, Identifiable, Sendable {
    public var targetURL: URL
    public var imageURL: URL
    public var threadID: String?

    public var id: String {
        "\(targetURL.absoluteString)#\(imageURL.absoluteString)"
    }

    public var isThreadTarget: Bool {
        threadID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public init(targetURL: URL, imageURL: URL, threadID: String? = nil) {
        self.targetURL = targetURL
        self.imageURL = imageURL
        self.threadID = threadID
    }
}

public struct ForumBoardPage: Codable, Equatable, Sendable {
    public var board: ForumBoardSummary
    public var subBoards: [ForumBoardSummary]
    public var pinnedItems: [ForumPinnedItem]
    public var threads: [ForumThreadSummary]
    public var pageNavigation: ForumPageNavigation?
    public var filters: [ForumFilterOption]
    public var orders: [ForumOrderOption]
    public var formHash: String?
    public var fetchedAt: Date

    public init(
        board: ForumBoardSummary,
        subBoards: [ForumBoardSummary] = [],
        pinnedItems: [ForumPinnedItem] = [],
        threads: [ForumThreadSummary] = [],
        pageNavigation: ForumPageNavigation? = nil,
        filters: [ForumFilterOption] = [],
        orders: [ForumOrderOption] = [],
        formHash: String? = nil,
        fetchedAt: Date = .now
    ) {
        self.board = board
        self.subBoards = subBoards
        self.pinnedItems = pinnedItems
        self.threads = threads
        self.pageNavigation = pageNavigation
        self.filters = filters
        self.orders = orders
        self.formHash = formHash
        self.fetchedAt = fetchedAt
    }
}

public struct ForumThreadSummary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var tid: String
    public var title: String
    public var url: URL
    public var fid: String?
    public var authorName: String?
    public var authorID: String?
    public var authorAvatarURL: URL?
    public var description: String?
    public var tag: String?
    public var isPoll: Bool
    public var replyCount: Int?
    public var viewCount: Int?
    public var lastActivityText: String?

    public var id: String { tid }

    public init(
        tid: String,
        title: String,
        url: URL,
        fid: String? = nil,
        authorName: String? = nil,
        authorID: String? = nil,
        authorAvatarURL: URL? = nil,
        description: String? = nil,
        tag: String? = nil,
        isPoll: Bool = false,
        replyCount: Int? = nil,
        viewCount: Int? = nil,
        lastActivityText: String? = nil
    ) {
        self.tid = tid
        self.title = title
        self.url = url
        self.fid = fid
        self.authorName = authorName
        self.authorID = authorID
        self.authorAvatarURL = authorAvatarURL
        self.description = description
        self.tag = tag
        self.isPoll = isPoll
        self.replyCount = replyCount
        self.viewCount = viewCount
        self.lastActivityText = lastActivityText
    }
}

public struct ForumPinnedItem: Codable, Equatable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case thread
        case announcement
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var url: URL
    public var threadID: String?

    public init(id: String, kind: Kind, title: String, url: URL, threadID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.threadID = threadID
    }
}

public struct ForumPageNavigation: Codable, Equatable, Hashable, Sendable {
    public var currentPage: Int
    public var totalPages: Int?

    public init(currentPage: Int, totalPages: Int? = nil) {
        self.currentPage = currentPage
        self.totalPages = totalPages
    }
}

public struct ForumFilterOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ForumOrderOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var filter: String?
    public var orderBy: String?

    public init(id: String, title: String, filter: String? = nil, orderBy: String? = nil) {
        self.id = id
        self.title = title
        self.filter = filter
        self.orderBy = orderBy
    }
}

public struct ForumSearchPage: Codable, Equatable, Sendable {
    public var query: String
    public var searchID: String?
    public var totalCount: Int?
    public var results: [ForumThreadSummary]
    public var pageNavigation: ForumPageNavigation?

    public init(
        query: String,
        searchID: String? = nil,
        totalCount: Int? = nil,
        results: [ForumThreadSummary],
        pageNavigation: ForumPageNavigation? = nil
    ) {
        self.query = query
        self.searchID = searchID
        self.totalCount = totalCount
        self.results = results
        self.pageNavigation = pageNavigation
    }
}
