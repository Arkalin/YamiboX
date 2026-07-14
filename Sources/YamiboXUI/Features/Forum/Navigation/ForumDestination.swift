import Foundation
import YamiboXCore

enum ForumDestination: Hashable {
    case board(fid: String, title: String?, page: Int?)
    case search(fid: String?)
    case userSpace(uid: String?, name: String?, section: UserSpaceSection, subPage: UserSpaceSubPage)
    case messageCenter(tab: MessageCenterTab)
    case privateMessage(uid: String, name: String?)
    case blog(blogID: String, uid: String?, title: String?)
    case novelDetail(NovelDetailLaunchContext)
    case mangaDetail(MangaDetailLaunchContext)
    case threadReader(ThreadNovelLaunchContext)
    /// A thread URL that still needs `YamiboThreadRouteResolver` before it can
    /// render: the pushed screen resolves in place (spinner first), so the
    /// findpost page lookup stays visible instead of happening before any
    /// navigation. Only `.readerOverlay` stacks produce this.
    case threadLink(url: URL, title: String?, containingFid: String?, authorID: String?, isDiscussionView: Bool)
    case web(URL)
}

/// How a `ForumDestinationNavigator` treats thread links.
enum ForumNavigationMode {
    /// The forum tab: thread taps go through content classification
    /// (novel/manga detail pages, direct manga reader, native thread reader).
    case forumTab
    /// A forum stack layered on top of an active reader (原帖/评论跳转 and the
    /// reader's chapter-comments sheet). Everything stays inside this stack:
    /// every thread link opens as a native thread reader page and full
    /// novel/manga readers are never launched, because a second reader cannot
    /// be presented while one is already covering the app.
    case readerOverlay
}
