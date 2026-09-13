import Observation
import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

struct MineSidebarFixture: View {
    @State private var model = MineSidebarFixtureModel()
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            if model.isLoaded {
                TabView(selection: $selectedTab) {
                    MineHomeView(
                        dependencies: model.context.accountDependencies,
                        settingsDependencies: model.context.settingsDependencies,
                        appModel: model.appModel,
                        likeDependencies: model.context.likeLibraryDependencies
                    )
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
                    .tag(0)
                    Text("侧栏状态保留验收")
                        .accessibilityIdentifier("mine.fixture.other")
                        .tabItem { Label("验收页", systemImage: "checkmark.circle") }
                        .tag(1)
                    if ProcessInfo.processInfo.environment["MINE_SIDEBAR_ALIGNMENT_FIXTURE"] == "1" {
                        FavoritesNavigationHostView(
                            dependencies: model.context.libraryDependencies,
                            appModel: model.appModel
                        )
                        .tabItem { Label("收藏", systemImage: "heart.text.square") }
                        .tag(2)
                    }
                }
                .transformEnvironment(\.horizontalSizeClass) { sizeClass in
                    // Trait regression harness; real window resizing is verified separately.
                    if ProcessInfo.processInfo.environment["MINE_SIDEBAR_COMPACT_FIXTURE"] == "1" {
                        sizeClass = .compact
                    }
                }
            } else if let error = model.error {
                Text(error).accessibilityIdentifier("mine.fixture.error")
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(.light)
        .task { await model.load() }
    }
}

@MainActor
@Observable
private final class MineSidebarFixtureModel {
    let context: YamiboAppContext
    let appModel: YamiboAppModel
    var isLoaded = false
    var error: String?

    init() {
        let suite = "mine-sidebar-fixture-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: UserDefaults(suiteName: suite)!),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
            grdbRootDirectory: root,
            cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: suite)!,
            clearsWebDataOnReset: false
        )
        appModel = YamiboAppModel(appContext: context)
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            var library = FavoriteLibraryDocument()
            if ProcessInfo.processInfo.environment["FAVORITES_COLLECTION_TAP_FIXTURE"] == "1" {
                _ = library.createCollection(categoryID: library.defaultCategory.id, name: "合集点击验收")
                if let rawLayout = ProcessInfo.processInfo.environment["FAVORITES_COLLECTION_LAYOUT"],
                   let layout = FavoriteLibraryLayoutMode(rawValue: rawLayout) {
                    _ = try await context.settingsStore.update { $0.favorites.layoutMode = layout }
                }
            }
            let locations: [FavoriteLocation] = [.category(library.defaultCategory.id)]
            library.upsertItem(try FavoriteItem(
                target: .novelThread(threadID: "mine-novel"),
                title: "侧栏验收小说",
                locations: locations
            ))
            library.upsertItem(try FavoriteItem(
                target: .mangaThread(threadID: "mine-manga-chapter"),
                title: "侧栏验收漫画",
                locations: locations
            ))
            try await context.localFavoriteLibraryStore.save(library)
            let chapter = NovelChapterIdentity(rawValue: "post:mine#chapter:0")
            let likes = [
                LikeItem(
                    id: "mine-fixture-novel-like", workKey: .novel(threadID: "mine-novel"), kind: .text,
                    excerptText: "这是一段仅用于离线导航验收的小说摘录。",
                    anchor: .novelText(.init(
                        chapterIdentity: chapter,
                        textSegmentIdentity: .init(rawValue: "post:mine#chapter:0#text:0"),
                        range: .init(location: 0, length: 20), view: 1, resolvedAuthorID: "1"
                    )),
                    style: .yellow, chapterTitle: "第一章"
                ),
                LikeItem(
                    id: "mine-fixture-manga-like", workKey: .mangaTitle(cleanBookName: "侧栏验收漫画"), kind: .image,
                    sourceImageURL: URL(fileURLWithPath: "/mine-sidebar-fixture.png"),
                    anchor: .mangaImage(.init(chapterTID: "mine-manga-chapter", pageLocalIndex: 0)),
                    chapterTitle: "第一话"
                )
            ]
            try await context.likeLibraryDependencies.likeStore.replaceAll(likes)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).pngData { drawing in
                UIColor.systemTeal.setFill()
                drawing.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                UIColor.systemYellow.setFill()
                drawing.fill(CGRect(x: 100, y: 100, width: 400, height: 600))
            }
            try await context.likeLibraryDependencies.likeImageStore.save(
                image, id: "mine-fixture-manga-like", sourceURL: nil
            )
            isLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
