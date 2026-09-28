/// What `toggle(...)` did, so the reader can pick the right haptic and the
/// right button state without re-reading the store.
public enum BookmarkToggleOutcome: Hashable, Sendable {
    case added(BookmarkItem)
    case removed(BookmarkItem)

    public var isBookmarked: Bool {
        switch self {
        case .added: true
        case .removed: false
        }
    }

    public var item: BookmarkItem {
        switch self {
        case let .added(item), let .removed(item): item
        }
    }
}
