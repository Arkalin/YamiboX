import Observation
import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

struct LikeListFixture: View {
    @State private var model = LikeListFixtureModel()
    @State private var segment = ReaderAnnotationSegment.likes
    @State private var openedAnchor = false
    private let environment = ProcessInfo.processInfo.environment

    var body: some View {
        LikeListFixtureNavigation(
            usesCategoryNavigation: UIDevice.current.userInterfaceIdiom == .pad
                && !["reader", "novel", "manga"].contains(environment["LIKES_FIXTURE_ENTRY"] ?? "")
        ) {
            if model.isLoaded {
                switch environment["LIKES_FIXTURE_ENTRY"] {
                case "reader":
                    ReaderAnnotationPanel(
                        work: .novel(threadID: "100"), workTitle: "测试小说：长夜里的来信",
                        like: model.context.likeLibraryDependencies, annotationSegment: $segment, initialTab: .likes,
                        onOpenBookmark: { _ in }, onOpenLikeAnchor: { _ in openedAnchor = true }, onDismiss: {}
                    ) { _, _ in
                        List { Text("第一章 初次相遇") }
                    }
                case "novel", "manga":
                    LikeWorkItemsView(
                        work: environment["LIKES_FIXTURE_ENTRY"] == "manga" ? .mangaTitle(cleanBookName: "测试漫画") : .novel(threadID: "100"),
                        workTitle: environment["LIKES_FIXTURE_ENTRY"] == "manga" ? "测试漫画" : "测试小说：长夜里的来信",
                        like: model.context.likeLibraryDependencies,
                        onOpenAnchor: { _ in openedAnchor = true }, onDismiss: nil
                    )
                default:
                    LikeWorkListView(likeDependencies: model.context.likeLibraryDependencies,
                        contentCoverStore: model.context.contentCoverStore,
                        favoriteLibraryStore: model.context.localFavoriteLibraryStore,
                        settingsStore: model.context.settingsStore, appModel: model.appModel)
                }
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if openedAnchor { Text("已跳转原文").accessibilityIdentifier("likes-fixture-opened") }
        }
        .preferredColorScheme(environment["LIKES_FIXTURE_DARK"] == "1" ? .dark : .light)
        .dynamicTypeSize(environment["LIKES_FIXTURE_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
        .task { await model.load() }
    }
}

private struct LikeListFixtureNavigation<Content: View>: View {
    let usesCategoryNavigation: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if usesCategoryNavigation {
            content()
        } else {
            NavigationStack {
                content()
            }
        }
    }
}

@MainActor @Observable
private final class LikeListFixtureModel {
    let context: YamiboAppContext
    let appModel: YamiboAppModel
    var isLoaded = false

    init() {
        let suite = "like-list-fixture"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("like-list-fixture")
        context = YamiboAppContext(sessionStore: SessionStore(defaults: UserDefaults(suiteName: suite)!), settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
            grdbRootDirectory: root, cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: suite)!, clearsWebDataOnReset: false)
        appModel = YamiboAppModel(appContext: context)
    }

    func load() async {
        let likes = context.likeLibraryDependencies
        if ProcessInfo.processInfo.environment["LIKES_FIXTURE_KEEP_DATA"] != "1" {
            var library = FavoriteLibraryDocument()
            library.upsertItem(try! FavoriteItem(target: .novelThread(threadID: "100"), title: "测试小说：长夜里的来信", locations: [.category(library.defaultCategory.id)]))
            library.upsertItem(try! FavoriteItem(target: .novelThread(threadID: "200"), title: "另一部小说：夏日记事", locations: [.category(library.defaultCategory.id)]))
            try? await context.localFavoriteLibraryStore.save(library)
            let chapter = NovelChapterIdentity(rawValue: "post:1000#chapter:0")
            let items = [
                LikeItem(id: "fixture-text", workKey: .novel(threadID: "100"), kind: .text,
                    excerptText: "夜色渐深，她终于读完了那封迟到的信。", anchor: .novelText(.init(chapterIdentity: chapter, textSegmentIdentity: .init(rawValue: "post:1000#chapter:0#text:0"), range: .init(location: 0, length: 24), view: 1, resolvedAuthorID: "1")),
                    style: .yellow, note: "记住这一段细腻的描写。", chapterTitle: "第一章 初次相遇", createdAt: .now.addingTimeInterval(-86400)),
                LikeItem(id: "fixture-image", workKey: .novel(threadID: "100"), kind: .image,
                    sourceImageURL: URL(fileURLWithPath: "/like-fixture-image.png"),
                    anchor: .novelImage(.init(chapterIdentity: chapter, imageSegmentIdentity: "post:1000#chapter:0#image:0", view: 1, resolvedAuthorID: "1")),
                    note: "这一页的构图很好看。", chapterTitle: "第二章 漫长的章节标题用于确认窄屏下的来源与日期不会互相挤压", createdAt: .now.addingTimeInterval(-172800)),
                LikeItem(id: "fixture-legacy", workKey: .novel(threadID: "100"), kind: .text,
                    excerptText: "没有章节缓存的旧摘录仍然正常显示。", anchor: .novelText(.init(chapterIdentity: chapter, textSegmentIdentity: .init(rawValue: "post:1000#chapter:0#text:1"), range: .init(location: 0, length: 24), view: 1, resolvedAuthorID: "1")), style: .underline),
                LikeItem(id: "fixture-other", workKey: .novel(threadID: "200"), kind: .text,
                    excerptText: "夏天的故事", anchor: .novelText(.init(chapterIdentity: chapter, textSegmentIdentity: .init(rawValue: "post:1000#chapter:0#text:0"), range: .init(location: 0, length: 6), view: 1, resolvedAuthorID: "1")), style: .pink, chapterTitle: "序章"),
                LikeItem(id: "fixture-manga", workKey: .mangaTitle(cleanBookName: "测试漫画"), kind: .image,
                    sourceImageURL: URL(fileURLWithPath: "/like-fixture-manga.png"), anchor: .mangaImage(.init(chapterTID: "300", pageLocalIndex: 0)), chapterTitle: "第十二话")
            ]
            try? await likes.likeStore.clearAll()
            try? await likes.likeStore.replaceAll(items)
            if ProcessInfo.processInfo.environment["LIKES_FIXTURE_IMAGE_FAILURE"] != "1" {
                let data = imageData()
                for id in ["fixture-image", "fixture-manga"] {
                    try? await likes.likeImageStore.save(data, id: id, sourceURL: nil)
                }
            } else {
                for id in ["fixture-image", "fixture-manga"] { try? await likes.likeImageStore.delete(id: id) }
            }
        }
        isLoaded = true
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 800, height: 450)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 450))
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 400, y: 0, width: 400, height: 450))
            ("图片摘录" as NSString).draw(at: CGPoint(x: 280, y: 190), withAttributes: [.font: UIFont.systemFont(ofSize: 48, weight: .semibold), .foregroundColor: UIColor.black])
        }
    }
}
