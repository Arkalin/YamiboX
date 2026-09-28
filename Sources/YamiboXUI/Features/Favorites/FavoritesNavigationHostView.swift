import SwiftUI
import YamiboXCore

struct FavoritesNavigationHostView: View {
    let dependencies: LibraryDependencies
    let forumDependencies: ForumNavigationDependencies
    let appModel: YamiboAppModel

    var body: some View {
        LocalFavoritesRootView(dependencies: dependencies, forumDependencies: forumDependencies, appModel: appModel)
    }
}
