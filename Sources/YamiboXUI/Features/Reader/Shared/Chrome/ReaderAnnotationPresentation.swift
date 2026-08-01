import Foundation
import YamiboXCore

/// The two annotation segments remembered between openings of the reader
/// library panel. Chapters has its own tab, but is intentionally not remembered
/// here: reopening from the annotation capsule should retain its prior
/// bookmarks-or-likes destination.
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

/// Tabs shown in the reader's unified chapters, bookmarks, and likes panel.
///
/// This is distinct from `ReaderAnnotationSegment`: a reader can expose the
/// annotation tabs without a chapter directory (for example, non-smart manga),
/// and the chapter tab must not change the remembered annotation destination.
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

/// Drives the 书签与喜欢 capsule that sits directly under the 目录 capsule.
///
/// The capsule shows one combined count rather than two: it is a navigation
/// entry point, not a dashboard — "how much have I collected in this work" is
/// what a reader wants at a glance, and the split is visible the moment the
/// panel opens.
public struct ReaderAnnotationCapsulePresentation: Equatable, Sendable {
    /// Counts above this render as "99+". Keeps the capsule's trailing slot
    /// from growing wide enough to squeeze the title on a small screen.
    static let displayedCountLimit = 99

    public var bookmarkCount: Int
    public var likeCount: Int

    public init(bookmarkCount: Int, likeCount: Int) {
        self.bookmarkCount = max(0, bookmarkCount)
        self.likeCount = max(0, likeCount)
    }

    public var totalCount: Int { bookmarkCount + likeCount }

    /// The capsule only exists once the work has something to show; an empty
    /// entry point would be permanent chrome that never leads anywhere.
    public var isVisible: Bool { totalCount > 0 }

    public var countText: String {
        totalCount > Self.displayedCountLimit ? "\(Self.displayedCountLimit)+" : "\(totalCount)"
    }

    public var title: String { L10n.string("annotations.title") }

    /// Which segment the panel should land on. Bookmarks is the default; a
    /// work with only likes opens on likes so the first screen is never empty.
    public func initialSegment(remembering remembered: ReaderAnnotationSegment?) -> ReaderAnnotationSegment {
        if let remembered { return remembered }
        if bookmarkCount == 0, likeCount > 0 { return .likes }
        return .bookmarks
    }
}

/// One row in the bookmark segment. Built from a `BookmarkItem` plus whatever
/// the reader can resolve live, so the row renders with nothing but the stored
/// snapshot when a chapter title is unavailable.
public struct ReaderBookmarkRowPresentation: Equatable, Sendable, Identifiable {
    public var id: String
    public var primaryText: String
    public var secondaryText: String?

    public init(item: BookmarkItem, relativeDateText: String) {
        self.id = item.id
        switch item.anchor {
        case let .novel(anchor):
            // A reflow reader has no stable page number, so the body snapshot
            // is the only thing that tells two bookmarks in one chapter apart.
            let snapshot = Self.presentable(item.excerptText)
            let chapterTitle = Self.presentable(anchor.chapterTitle)
            self.primaryText = snapshot
                ?? chapterTitle
                ?? L10n.string("annotations.bookmark.untitled_position")
            // Without a snapshot the chapter title has already been promoted
            // to the primary line, so repeating it below would be noise.
            let secondaryChapter = snapshot == nil ? nil : chapterTitle
            self.secondaryText = secondaryChapter.map { "\($0) · \(relativeDateText)" } ?? relativeDateText
        case let .manga(anchor):
            // Manga pages *do* have a stable index, so the row leads with it
            // and needs no body snapshot at all.
            let page = L10n.string("reader.page_number_compact", anchor.pageLocalIndex + 1)
            self.primaryText = Self.presentable(anchor.chapterTitle).map { "\($0) · \(page)" } ?? page
            self.secondaryText = relativeDateText
        }
    }

    /// Trimmed, or nil when there is nothing left to show. Whitespace-only
    /// values must collapse to nil, not to an empty string, or the fallback
    /// chain silently keeps them.
    private static func presentable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
