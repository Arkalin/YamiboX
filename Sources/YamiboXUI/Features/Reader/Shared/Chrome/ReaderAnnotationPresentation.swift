import Foundation
import YamiboXCore

public enum ReaderAnnotationSegment: String, CaseIterable, Hashable, Sendable {
    case bookmarks
    case likes

    public var title: String {
        switch self {
        case .bookmarks: L10n.string("annotations.segment.bookmarks")
        case .likes: L10n.string("annotations.segment.likes")
        }
    }
}

enum ReaderLibraryPanelTab: Hashable, Sendable {
    case chapters
    case bookmarks
    case likes

    var title: String {
        switch self {
        case .chapters: L10n.string("annotations.segment.chapters")
        case .bookmarks: L10n.string("annotations.segment.bookmarks")
        case .likes: L10n.string("annotations.segment.likes")
        }
    }

    var annotationSegment: ReaderAnnotationSegment? {
        switch self {
        case .chapters: nil
        case .bookmarks: .bookmarks
        case .likes: .likes
        }
    }

    init(annotationSegment: ReaderAnnotationSegment) {
        switch annotationSegment {
        case .bookmarks: self = .bookmarks
        case .likes: self = .likes
        }
    }

    static func available(includingChapters: Bool) -> [Self] {
        includingChapters ? [.chapters, .bookmarks, .likes] : [.bookmarks, .likes]
    }
}

public struct ReaderAnnotationCapsulePresentation: Equatable, Sendable {
    static let displayedCountLimit = 99

    public var bookmarkCount: Int
    public var likeCount: Int

    public init(bookmarkCount: Int, likeCount: Int) {
        self.bookmarkCount = max(0, bookmarkCount)
        self.likeCount = max(0, likeCount)
    }

    public var totalCount: Int { bookmarkCount + likeCount }

    public var isVisible: Bool { totalCount > 0 }

    public var countText: String {
        totalCount > Self.displayedCountLimit ? "\(Self.displayedCountLimit)+" : "\(totalCount)"
    }

    public var title: String { L10n.string("annotations.title") }

    public func initialSegment(remembering remembered: ReaderAnnotationSegment?) -> ReaderAnnotationSegment {
        if let remembered { return remembered }
        if bookmarkCount == 0, likeCount > 0 { return .likes }
        return .bookmarks
    }
}

public struct ReaderBookmarkRowPresentation: Equatable, Sendable, Identifiable {
    public var id: String
    public var primaryText: String
    public var secondaryText: String?

    public init(item: BookmarkItem, relativeDateText: String) {
        self.id = item.id
        switch item.anchor {
        case let .novel(anchor):
            let snapshot = Self.presentable(item.excerptText)
            let chapterTitle = Self.presentable(anchor.chapterTitle)
            self.primaryText = snapshot
                ?? chapterTitle
                ?? L10n.string("annotations.bookmark.untitled_position")
            let secondaryChapter = snapshot == nil ? nil : chapterTitle
            self.secondaryText = secondaryChapter.map { "\($0) · \(relativeDateText)" } ?? relativeDateText
        case let .manga(anchor):
            let page = L10n.string("reader.page_number_compact", anchor.pageLocalIndex + 1)
            self.primaryText = Self.presentable(anchor.chapterTitle).map { "\($0) · \(page)" } ?? page
            self.secondaryText = relativeDateText
        }
    }

    private static func presentable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
