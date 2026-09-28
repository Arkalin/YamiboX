import Foundation

extension FavoriteUpdateSummary {
    /// Shared by in-app update lists and system notification bodies.
    public var displayText: String {
        switch self {
        case let .newReplies(count):
            L10n.string("favorites.updates.summary.replies", count)
        case let .newPages(count):
            L10n.string("favorites.updates.summary.pages", count)
        case let .newChapters(count):
            L10n.string("favorites.updates.summary.new_chapters", count)
        case .changed:
            L10n.string("favorites.updates.summary.changed")
        }
    }
}
