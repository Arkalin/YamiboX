import XCTest
import YamiboXCore
@testable import YamiboXUI

@MainActor
final class AppBootstrapProgressTests: XCTestCase {
    func testLaunchReportsOperationsInExecutionOrder() async throws {
        let fixture = try makeSystemSettingsFixture()
        let workflow = AppContinuityWorkflow(appContext: fixture.appContext)
        let recorder = BootstrapProgressRecorder()

        _ = await workflow.launchIfNeeded(canRestoreReaderRoute: true) { phase in
            await recorder.record(phase)
        }

        XCTAssertEqual(recorder.phases, [
            .loadingSession, .loadingProfile, .loadingSettings, .loadingFavorites,
            .synchronizingWebDAV, .loadingReadingPosition,
        ])
    }

    func testLaunchDoesNotReportReadingPositionWhenRestorationIsSkipped() async throws {
        let fixture = try makeSystemSettingsFixture()
        let workflow = AppContinuityWorkflow(appContext: fixture.appContext)
        let recorder = BootstrapProgressRecorder()

        _ = await workflow.launchIfNeeded(canRestoreReaderRoute: false) { phase in
            await recorder.record(phase)
        }

        XCTAssertEqual(recorder.phases, [
            .loadingSession, .loadingProfile, .loadingSettings, .loadingFavorites,
            .synchronizingWebDAV,
        ])
    }

    func testBootstrapClearsProgressOnCompletionAndRemainsIdempotent() async throws {
        let fixture = try makeSystemSettingsFixture()
        let model = YamiboAppModel(appContext: fixture.appContext)
        XCTAssertNil(model.bootstrapPhase)

        await model.bootstrapIfNeeded()

        XCTAssertNotNil(model.bootstrapState)
        XCTAssertNil(model.bootstrapPhase)
        XCTAssertFalse(model.isBootstrapping)

        await model.bootstrapIfNeeded()
        XCTAssertNil(model.bootstrapPhase)
        XCTAssertFalse(model.isBootstrapping)

        await model.bootstrap()
        XCTAssertNil(model.bootstrapPhase)
        XCTAssertFalse(model.isBootstrapping)
    }

    func testEveryStartupPhaseHasLocalizedOperationText() {
        let phases: [AppBootstrapPhase] = [
            .loadingSession, .loadingProfile, .loadingSettings, .loadingFavorites,
            .synchronizingWebDAV, .loadingReadingPosition,
        ]
        let messages = phases.map { String(localized: $0.startupMessage) }

        XCTAssertEqual(Set(messages).count, phases.count)
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.hasPrefix("app.startup."))
        }
    }
}

@MainActor
private final class BootstrapProgressRecorder {
    var phases: [AppBootstrapPhase] = []

    func record(_ phase: AppBootstrapPhase) async {
        phases.append(phase)
    }
}
