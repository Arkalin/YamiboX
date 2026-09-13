import Observation
import SwiftUI
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class LibraryCategoryEmbeddingTests: XCTestCase {
    func testEmbeddedHistoryTracksParentCategoryWithoutCreatingAnotherSplit() async throws {
        let context = try makeSystemSettingsFixture().appContext
        let appModel = YamiboAppModel(appContext: context)
        let selection = CategorySelection()
        selection.history = .novel
        let host = UIHostingController(rootView: EmbeddedHistoryHarness(
            context: context, appModel: appModel, selection: selection
        ))
        let window = show(host)
        defer { window.isHidden = true; window.rootViewController = nil }

        for category in [BrowsingHistoryFilter.novel, .manga, .normal, .all] {
            selection.history = category
            try await waitForTitle(L10n.string("forum.history"), in: host.view)
            XCTAssertFalse(controllers(in: host).contains { $0 is UISplitViewController })
            XCTAssertEqual(selection.history, category)
        }
    }

    func testEmbeddedLikesTracksParentCategoryWithoutCreatingAnotherSplit() async throws {
        let context = try makeSystemSettingsFixture().appContext
        let appModel = YamiboAppModel(appContext: context)
        let selection = CategorySelection()
        selection.likes = .manga
        let host = UIHostingController(rootView: EmbeddedLikesHarness(
            context: context, appModel: appModel, selection: selection
        ))
        let window = show(host)
        defer { window.isHidden = true; window.rootViewController = nil }

        for category in [LikeWorkFilter.manga, .novel, .all] {
            selection.likes = category
            try await waitForTitle(category.navigationTitle(usesSidebar: false, selectedCount: nil), in: host.view)
            XCTAssertFalse(controllers(in: host).contains { $0 is UISplitViewController })
            XCTAssertEqual(selection.likes, category)
        }
    }

    func testNavigationOwnershipDefaultsToStandaloneButCanBeDisabled() {
        let standalone = LibraryPageNavigation {
            Text("Entries")
        }
        let embedded = LibraryPageNavigation(ownsNavigation: false) {
            Text("Entries")
        }
        XCTAssertTrue(standalone.ownsNavigation)
        XCTAssertFalse(embedded.ownsNavigation)
    }

    func testEmbeddedLikesPublishesSelectionModeOnAppearanceAndDisappearance() async throws {
        let context = try makeSystemSettingsFixture().appContext
        let appModel = YamiboAppModel(appContext: context)
        var selectionModes: [Bool] = []
        let host = UIHostingController(rootView: AnyView(NavigationStack {
            LikeWorkListView(likeDependencies: context.likeLibraryDependencies,
                contentCoverStore: context.contentCoverStore,
                favoriteLibraryStore: context.localFavoriteLibraryStore,
                settingsStore: context.settingsStore, appModel: appModel,
                categorySelection: .constant(.all),
                onSelectionModeChange: { selectionModes.append($0) })
        }))
        let window = show(host)
        defer { window.isHidden = true; window.rootViewController = nil }

        try await waitForTitle(LikeWorkFilter.all.navigationTitle(usesSidebar: false, selectedCount: nil), in: host.view)
        XCTAssertEqual(selectionModes, [false])

        host.rootView = AnyView(Text("Removed"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while selectionModes.count < 2, ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(selectionModes, [false, false])
    }

    private func show(_ host: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        return window
    }

    private func waitForTitle(_ title: String, in view: UIView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            view.layoutIfNeeded()
            if navigationTitles(in: view).contains(title) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(navigationTitles(in: view).contains(title), "Expected \(title), found \(navigationTitles(in: view))")
    }

    private func navigationTitles(in view: UIView) -> [String] {
        let title = (view as? UINavigationBar)?.topItem?.title
        return (title.map { [$0] } ?? []) + view.subviews.flatMap { navigationTitles(in: $0) }
    }

    private func controllers(in controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap { controllers(in: $0) }
    }

    private struct EmbeddedHistoryHarness: View {
        let context: YamiboAppContext
        let appModel: YamiboAppModel
        @Bindable var selection: CategorySelection

        var body: some View {
            NavigationStack {
                BrowsingHistoryView(dependencies: context.libraryDependencies, appModel: appModel,
                    categorySelection: $selection.history)
            }
        }
    }

    private struct EmbeddedLikesHarness: View {
        let context: YamiboAppContext
        let appModel: YamiboAppModel
        @Bindable var selection: CategorySelection

        var body: some View {
            NavigationStack {
                LikeWorkListView(likeDependencies: context.likeLibraryDependencies,
                    contentCoverStore: context.contentCoverStore,
                    favoriteLibraryStore: context.localFavoriteLibraryStore,
                    settingsStore: context.settingsStore, appModel: appModel,
                    categorySelection: $selection.likes)
            }
        }
    }

    @Observable
    final class CategorySelection {
        var history = BrowsingHistoryFilter.all
        var likes = LikeWorkFilter.all
    }
}
