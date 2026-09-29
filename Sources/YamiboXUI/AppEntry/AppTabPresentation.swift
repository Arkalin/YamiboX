import YamiboXCore

extension AppTab {
    var title: String {
        switch self {
        case .bookshelf: L10n.string("tab.bookshelf")
        case .forum: L10n.string("tab.forum")
        case .favorites: L10n.string("tab.favorites")
        case .mine: L10n.string("tab.mine")
        case .messages: L10n.string("tab.messages")
        case .history: L10n.string("forum.history")
        case .likes: L10n.string("likes.section_title")
        }
    }

    var systemImage: String {
        switch self {
        case .bookshelf: "books.vertical"
        case .forum: "text.bubble"
        case .favorites: "heart.text.square"
        case .mine: "person.crop.circle"
        case .messages: "envelope"
        case .history: "clock.arrow.circlepath"
        case .likes: "heart"
        }
    }
}
