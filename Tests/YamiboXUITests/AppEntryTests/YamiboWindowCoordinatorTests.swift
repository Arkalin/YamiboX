import SwiftUI
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class YamiboWindowCoordinatorTests: XCTestCase {
    func testWindowsShareServicesButNotNavigationOrReaderSessions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.coordinator.makeModel(windowID: "first", initialTab: .forum)
        let second = fixture.coordinator.makeModel(windowID: "second", initialTab: .favorites)
        XCTAssertTrue(first.appContext === second.appContext)
        XCTAssertTrue(first.imagePipeline === second.imagePipeline)
        XCTAssertTrue(first.webSessionCoordinator === second.webSessionCoordinator)
        XCTAssertFalse(first.peripheralInput === second.peripheralInput)

        first.selectTab(.mine)
        first.presentNovelReader(novel("100", view: 3))
        second.presentNovelReader(novel("200", view: 8))
        XCTAssertEqual(second.selectedTab, .favorites)
        XCTAssertEqual(first.activeNovelContext?.threadID, "100")
        XCTAssertEqual(second.activeNovelContext?.threadID, "200")
        XCTAssertFalse(first.presentedReaderSession === second.presentedReaderSession)

        first.dismissNovelReader()
        XCTAssertNil(first.activeNovelContext)
        XCTAssertEqual(second.activeNovelContext?.initialView, 8)
    }

    func testReaderResumeStoresAreSceneLocalAndDismissingOneDoesNotClearAnother() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.coordinator.makeModel(windowID: "first")
        let second = fixture.coordinator.makeModel(windowID: "second")
        first.presentNovelReader(novel("100", view: 2))
        second.presentNovelReader(novel("200", view: 4))
        first.updateReaderResumeRoute(.novel(novel("100", view: 7)))

        XCTAssertEqual(fixture.coordinator.resumeRouteStore(windowID: "first").loadSync(), .novel(novel("100", view: 7)))
        XCTAssertEqual(fixture.coordinator.resumeRouteStore(windowID: "second").loadSync(), .novel(novel("200", view: 4)))
        XCTAssertNil(fixture.context.readerResumeRouteStore.loadSync())
        first.dismissNovelReader()
        XCTAssertNil(fixture.coordinator.resumeRouteStore(windowID: "first").loadSync())
        XCTAssertEqual(fixture.coordinator.resumeRouteStore(windowID: "second").loadSync(), .novel(novel("200", view: 4)))
    }

    func testBootstrapRestoresEachSceneAndMigratesLegacyRouteOnlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.context.readerResumeRouteStore.saveSync(.novel(novel("legacy", view: 3)))
        try fixture.coordinator.resumeRouteStore(windowID: "second").saveSync(.novel(novel("scene", view: 5)))
        let first = fixture.coordinator.makeModel(windowID: "first")
        let second = fixture.coordinator.makeModel(windowID: "second")
        await first.bootstrapIfNeeded()
        await second.bootstrapIfNeeded()
        XCTAssertEqual(first.activeNovelContext?.threadID, "legacy")
        XCTAssertEqual(second.activeNovelContext?.threadID, "scene")
        let third = fixture.coordinator.makeModel(windowID: "third")
        await third.bootstrapIfNeeded()
        XCTAssertNil(third.activeNovelContext)
        XCTAssertNil(fixture.context.readerResumeRouteStore.loadSync())
    }

    func testAccountLifecyclePublishesToEveryWindowAndClearsDisconnectedRestoration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.coordinator.makeModel(windowID: "first")
        let second = fixture.coordinator.makeModel(windowID: "second")
        await first.bootstrapIfNeeded()
        await second.bootstrapIfNeeded()
        first.presentNovelReader(novel("100", view: 2))
        second.presentNovelReader(novel("200", view: 4))
        try fixture.coordinator.resumeRouteStore(windowID: "disconnected").saveSync(.novel(novel("old", view: 6)))
        let firstGeneration = first.accountGeneration
        let secondGeneration = second.accountGeneration

        await fixture.context.accountTransitionLifecycle.didPublish()

        XCTAssertNotEqual(first.accountGeneration, firstGeneration)
        XCTAssertNotEqual(second.accountGeneration, secondGeneration)
        XCTAssertNil(first.activeNovelContext)
        XCTAssertNil(second.activeNovelContext)
        for id in ["first", "second", "disconnected"] {
            XCTAssertNil(fixture.coordinator.resumeRouteStore(windowID: id).loadSync())
        }
    }

    func testGlobalPhaseRemainsActiveUntilLastActiveSceneLeaves() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.coordinator.makeModel(windowID: "first")
        let second = fixture.coordinator.makeModel(windowID: "second")
        XCTAssertTrue(first.scenePhaseDidChange(.active))
        XCTAssertTrue(second.scenePhaseDidChange(.active))
        XCTAssertFalse(second.scenePhaseDidChange(.active))
        XCTAssertTrue(first.scenePhaseDidChange(.background))
        XCTAssertEqual(fixture.coordinator.aggregatePhase, .active)
        XCTAssertTrue(second.scenePhaseDidChange(.inactive))
        XCTAssertEqual(fixture.coordinator.aggregatePhase, .inactive)
        XCTAssertTrue(second.scenePhaseDidChange(.background))
        XCTAssertEqual(fixture.coordinator.aggregatePhase, .background)
    }

    func testKeyboardCaptureOnlyReceivesItsFocusedWindowEvents() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.coordinator.makeModel(windowID: "first")
        let second = fixture.coordinator.makeModel(windowID: "second")
        _ = first.scenePhaseDidChange(.active)
        _ = second.scenePhaseDidChange(.active)
        var firstCaptures = 0
        var secondCaptures = 0
        first.peripheralInput.beginKeyboardCapture { _ in firstCaptures += 1 }
        second.peripheralInput.beginKeyboardCapture { _ in secondCaptures += 1 }

        press(first)
        press(second)
        XCTAssertEqual(firstCaptures + secondCaptures, 0, "Two active windows without a known focus must not guess")
        fixture.coordinator.focus(windowID: "first")
        press(second)
        press(first)
        XCTAssertEqual(firstCaptures, 1)
        XCTAssertEqual(secondCaptures, 0)

        fixture.coordinator.focus(windowID: "second")
        press(second)
        XCTAssertEqual(secondCaptures, 1)
        XCTAssertFalse(first.ownsWebSessionPresentation)
        XCTAssertTrue(second.ownsWebSessionPresentation)
    }

    func testTextEditingAndCommandShortcutsDoNotTriggerReaderBindings() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.coordinator.makeModel(windowID: "first")
        _ = model.scenePhaseDidChange(.active)
        var captures = 0
        model.peripheralInput.beginKeyboardCapture { _ in captures += 1 }
        model.peripheralInput.handleWindowKey(code: 4, isPressed: true, isEditingText: true, hasCommandModifier: false)
        model.peripheralInput.handleWindowKey(code: 4, isPressed: true, isEditingText: false, hasCommandModifier: true)
        XCTAssertEqual(captures, 0)
        press(model)
        XCTAssertEqual(captures, 1)
    }

    func testWindowRequestCodableRoundTripPreservesReadingPosition() throws {
        let request = YamiboWindowRequest(readerRoute: .novel(novel("100", view: 9)))
        XCTAssertEqual(try JSONDecoder().decode(YamiboWindowRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func testColdLaunchForumRequestIsNotCoveredByLegacyReaderRestoration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.context.readerResumeRouteStore.saveSync(.novel(novel("legacy", view: 3)))
        let model = fixture.coordinator.makeModel(windowID: "first")
        let url = try XCTUnwrap(URL(string: "https://bbs.yamibo.com/thread-123-1-1.html"))
        model.openForumURL(url)
        await model.bootstrapIfNeeded()
        XCTAssertEqual(model.forumNavigationRequest?.url, url)
        XCTAssertNil(model.activeNovelContext)
        XCTAssertNil(fixture.coordinator.resumeRouteStore(windowID: "first").loadSync())
    }

    func testColdLaunchSearchRequestIsNotCoveredByReaderRestoration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.context.readerResumeRouteStore.saveSync(.novel(novel("legacy", view: 3)))
        let model = fixture.coordinator.makeModel(windowID: "first")
        model.openForumSearch()
        await model.bootstrapIfNeeded()
        XCTAssertNotNil(model.forumSearchRequest)
        XCTAssertNil(model.activeNovelContext)
    }

    func testAccountChangeDuringBootstrapDiscardsOldSnapshotAndRoute() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let settingsStore = fixture.context.settingsStore
        try fixture.context.readerResumeRouteStore.saveSync(.novel(novel("old-account", view: 3)))
        let model = coordinator.makeModel(windowID: "first")
        let result = await coordinator.bootstrap { phase in
            if phase == .loadingReadingPosition {
                _ = try? await settingsStore.update { $0.appearance.themePreset = .rose }
                await coordinator.publishAccountChange()
            }
        }
        XCTAssertNil(result.restoredRoute)
        XCTAssertEqual(result.bootstrapState.settings.appearance.themePreset, .rose)
        await model.bootstrapIfNeeded()
        XCTAssertNil(model.activeNovelContext)
        XCTAssertEqual(model.appThemePreset, .rose)
    }

    func testRestoreCannotOverwriteNavigationThatArrivesDuringAnAwait() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.coordinator.resumeRouteStore(windowID: "first")
        let workflow = AppContinuityWorkflow(appContext: fixture.context, readerResumeRouteStore: store)
        try store.saveSync(.novel(novel("old", view: 3)))
        let newRoute = ReaderResumeRoute.novel(novel("new", view: 8))
        let restored = await workflow.restoreExplicitly(canRestoreReaderRoute: true) { _ in
            workflow.readerRoutePresented(newRoute)
        }
        XCTAssertNil(restored)
        XCTAssertEqual(store.loadSync(), newRoute)
    }

    func testWebVerificationOwnerRemainsStableUntilItsSceneLeavesForeground() {
        XCTAssertEqual(YamiboWindowCoordinator.presentationOwner(
            current: "first", focused: "second", hasPresentation: true, currentOwnerIsActive: true
        ), "first")
        XCTAssertEqual(YamiboWindowCoordinator.presentationOwner(
            current: "first", focused: "second", hasPresentation: true, currentOwnerIsActive: false
        ), "second")
        XCTAssertEqual(YamiboWindowCoordinator.presentationOwner(
            current: "first", focused: "second", hasPresentation: false, currentOwnerIsActive: true
        ), "second")
    }

    func testSearchForUnboundSceneWaitsRatherThanOpeningInExistingWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.coordinator.makeModel(windowID: "first")
        fixture.coordinator.bind(sceneIdentifier: "first-scene", windowID: "first")
        fixture.coordinator.openForumSearch(sceneIdentifier: "second-scene")
        XCTAssertNil(first.forumSearchRequest)
        let second = fixture.coordinator.makeModel(windowID: "second")
        fixture.coordinator.bind(sceneIdentifier: "second-scene", windowID: "second")
        XCTAssertNotNil(second.forumSearchRequest)
        XCTAssertNil(first.forumSearchRequest)
    }

    private func press(_ model: YamiboAppModel) {
        model.peripheralInput.handleWindowKey(code: 4, isPressed: true, isEditingText: false, hasCommandModifier: false)
        model.peripheralInput.handleWindowKey(code: 4, isPressed: false, isEditingText: false, hasCommandModifier: false)
    }

    private func novel(_ threadID: String, view: Int) -> NovelLaunchContext {
        NovelLaunchContext(threadID: threadID, threadTitle: threadID, source: .resume, initialView: view)
    }

    private func makeFixture() throws -> Fixture {
        let context = try makeSystemSettingsFixture().appContext
        let suite = "window-coordinator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return Fixture(
            context: context,
            coordinator: YamiboWindowCoordinator(appContext: context, restorationDefaults: defaults),
            defaults: defaults,
            suite: suite
        )
    }

    @MainActor
    private struct Fixture {
        let context: YamiboAppContext
        let coordinator: YamiboWindowCoordinator
        let defaults: UserDefaults
        let suite: String

        func cleanUp() {
            coordinator.stopRuntime()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
