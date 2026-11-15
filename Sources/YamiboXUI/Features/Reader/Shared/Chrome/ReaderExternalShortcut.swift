import YamiboXCore

enum ReaderExternalShortcutTarget {
    case toolbar
    case comments
    case library(ReaderLibraryPanelTab)

    init(_ action: ExternalDisplayShortcutAction) {
        switch action {
        case .toolbar: self = .toolbar
        case .comments: self = .comments
        case .directory: self = .library(.chapters)
        case .bookmarks: self = .library(.bookmarks)
        case .likes: self = .library(.likes)
        }
    }
}
