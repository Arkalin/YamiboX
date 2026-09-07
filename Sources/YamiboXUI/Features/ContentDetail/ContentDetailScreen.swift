import SwiftUI
import YamiboXCore

enum ContentDetailDestination: Hashable {
    case novel(NovelDetailLaunchContext)
    case manga(MangaDetailLaunchContext)
}

enum ContentDetailAction {
    case readNovel(NovelLaunchContext)
    case readManga(MangaLaunchContext)
    case author(uid: String, name: String?)
    case discussion(ThreadNovelLaunchContext)
}

/// Entry-point-independent page assembly. The host owns the navigation stack
/// and decides how to present readers, authors and the original discussion.
struct ContentDetailScreen: View {
    let destination: ContentDetailDestination
    let novelDependencies: NovelDetailDependencies
    let mangaDependencies: MangaDetailDependencies
    let onAction: (ContentDetailAction) -> Void

    var body: some View {
        Group {
            switch destination {
            case let .novel(context):
                NovelDetailView(
                    model: NovelDetailViewModel(context: context, dependencies: novelDependencies),
                    onChapterTap: { onAction(.readNovel($0)) },
                    onUserTap: { onAction(.author(uid: $0, name: $1)) },
                    onViewThread: {
                        onAction(.discussion(ThreadNovelLaunchContext(
                            thread: context.thread, title: context.title,
                            authorID: context.authorID, isDiscussionView: true
                        )))
                    }
                )
            case let .manga(context):
                MangaDetailView(
                    model: MangaDetailViewModel(context: context, dependencies: mangaDependencies),
                    onChapterTap: { onAction(.readManga($0)) },
                    onViewThread: {
                        onAction(.discussion(ThreadNovelLaunchContext(
                            thread: context.thread, title: context.title, isDiscussionView: true
                        )))
                    }
                )
            }
        }
        .forumNavigationBarStyle()
    }
}
