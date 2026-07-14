import SwiftUI
import YamiboXCore

struct FavoritesNavigationHostView: View {
    let dependencies: LibraryDependencies
    let appModel: YamiboAppModel

    var body: some View {
        LocalFavoritesRootView(dependencies: dependencies, appModel: appModel)
    }
}
