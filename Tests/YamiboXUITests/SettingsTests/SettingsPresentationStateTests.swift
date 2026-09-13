import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class SettingsPresentationStateTests: XCTestCase {
    func testSuccessfulSignOutClosesItsHost() async throws {
        let fixture = try makeSystemSettingsFixture()
        var events: [String] = []
        let state = SettingsPresentationState(
            dependencies: fixture.appContext.settingsDependencies,
            onSignOut: {
                events.append("signOut")
                return nil
            },
            onApplicationReset: {},
            onClose: { events.append("close") }
        )

        XCTAssertTrue(state.canNavigate)
        await state.handleConfirmation(.signOut)

        XCTAssertEqual(events, ["signOut", "close"])
        XCTAssertTrue(state.canNavigate)
        XCTAssertFalse(state.isSigningOut)
    }

    func testFailedSignOutKeepsHostOpenAndPresentsSharedError() async throws {
        let fixture = try makeSystemSettingsFixture()
        let failure = LoadFailureDetails(message: "Sign out failed")
        var didClose = false
        let state = SettingsPresentationState(
            dependencies: fixture.appContext.settingsDependencies,
            onSignOut: { failure },
            onApplicationReset: {},
            onClose: { didClose = true }
        )

        await state.handleConfirmation(.signOut)

        XCTAssertFalse(didClose)
        XCTAssertEqual(state.viewModel.errorMessage, failure.summary)
        XCTAssertEqual(state.viewModel.errorDetails, failure)
        XCTAssertTrue(state.canNavigate)
    }

    func testInFlightSignOutBlocksNavigationAndDuplicateConfirmation() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.update { $0.appearance.themePreset = .rose }
        var continuation: CheckedContinuation<LoadFailureDetails?, Never>?
        var signOutCount = 0
        let state = SettingsPresentationState(
            dependencies: fixture.appContext.settingsDependencies,
            onSignOut: {
                signOutCount += 1
                return await withCheckedContinuation { continuation = $0 }
            },
            onApplicationReset: {},
            onClose: {}
        )
        let task = Task { await state.handleConfirmation(.signOut) }
        try await waitForSettings { continuation != nil }

        XCTAssertTrue(state.isSigningOut)
        XCTAssertFalse(state.canNavigate)
        await state.loadIfIdle()
        XCTAssertEqual(state.viewModel.general.themePreset, .classic)
        await state.handleConfirmation(.signOut)
        XCTAssertEqual(signOutCount, 1)

        continuation?.resume(returning: nil)
        await task.value
        XCTAssertTrue(state.canNavigate)
    }

    func testRepeatedActivationLoadPreservesSharedBusyActionAndCurrentValues() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.update { $0.appearance.themePreset = .rose }
        let state = SettingsPresentationState(
            dependencies: fixture.appContext.settingsDependencies,
            onSignOut: { nil },
            onApplicationReset: {},
            onClose: {}
        )

        for action: SystemSettingsAction in [.loading, .clearingImageCache, .resettingApplication] {
            state.viewModel.storage.activeAction = action
            await state.loadIfIdle()
            await state.loadIfIdle()

            XCTAssertEqual(state.viewModel.storage.activeAction, action)
            XCTAssertFalse(state.canNavigate)
            XCTAssertEqual(state.viewModel.general.themePreset, .classic)
        }

        state.viewModel.storage.activeAction = nil
        await state.loadIfIdle()
        XCTAssertEqual(state.viewModel.general.themePreset, .rose)
        XCTAssertTrue(state.canNavigate)
    }

    func testResetClosesHostBeforeCallingApplicationReset() async throws {
        let fixture = try makeSystemSettingsFixture()
        var events: [String] = []
        let state = SettingsPresentationState(
            dependencies: fixture.appContext.settingsDependencies,
            onSignOut: { nil },
            onApplicationReset: { events.append("reset") },
            onClose: { events.append("close") }
        )

        await state.handleApplicationReset()

        XCTAssertEqual(events, ["close", "reset"])
    }
}
