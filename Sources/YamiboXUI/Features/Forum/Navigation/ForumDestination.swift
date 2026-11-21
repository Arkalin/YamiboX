import Foundation
import YamiboXCore

enum ForumDestination: Hashable {
    case home
    case tag(target: ForumTagTarget, page: Int)
    case browsingHistory
    case board(fid: String, title: String?, page: Int?)
    case search(fid: String?)
    case userSpace(uid: String?, name: String?, section: UserSpaceSection, subPage: UserSpaceSubPage)
    case messageCenter(tab: MessageCenterTab)
    case creditLog
    case privateMessage(uid: String, name: String?)
    case blog(blogID: String, uid: String?, title: String?)
    case novelDetail(NovelDetailLaunchContext)
    case mangaDetail(MangaDetailLaunchContext)
    case threadReader(ThreadNovelLaunchContext)
    case threadLink(url: URL, title: String?, containingFid: String?, authorID: String?, isDiscussionView: Bool)
    case web(URL)
    case webFallback(URL)
    case postEditor(URL)
    case blogEditor(URL)
    case actionForm(URL)
    case announcement(URL)
}

enum ForumNavigationMode {
    case forumTab
    case contentBrowser
    case readerOverlay
}
