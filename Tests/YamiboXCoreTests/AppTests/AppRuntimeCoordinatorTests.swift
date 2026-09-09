import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("Application runtime")
@MainActor
struct AppRuntimeCoordinatorTests {
    @MainActor
    @Test func appRuntimeRegistersAllStoreStreamsBeforeReturningAndFiltersChangeIDs() async throws {
        let fixture = RuntimeFixture()
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }

        runtime.start()
        runtime.start()
        #expect(fixture.sources.map(\.registrations) == [1, 1, 1, 1])
        for source in fixture.sources {
            source.send("unrelated")
            source.send(source.changeID)
        }

        try await waitForMainActorCondition { fixture.changes == [1, 1, 1, 1] }
        try await waitForMainActorCondition { fixture.operations.allSatisfy { $0.starts == 1 } }
        #expect(fixture.changes == [1, 1, 1, 1])
        #expect(fixture.operations.map(\.starts) == [1, 1])
    }

    @MainActor
    @Test func appRuntimeStopCancelsSixTasksAndRestartUsesFreshStreams() async throws {
        let fixture = RuntimeFixture()
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }
        runtime.start()
        try await waitForMainActorCondition { fixture.operations.allSatisfy { $0.starts == 1 } }

        // Buffer events and stop without yielding, exercising cancellation before dispatch.
        for source in fixture.sources { source.send(source.changeID) }
        runtime.stop()
        runtime.stop()
        try await waitForMainActorCondition {
            fixture.sources.allSatisfy { $0.terminations == 1 }
                && fixture.operations.allSatisfy { $0.cancelledExits == 1 }
        }
        #expect(fixture.changes == [0, 0, 0, 0])
        #expect(fixture.events == ["invalidate"])

        runtime.start()
        #expect(fixture.sources.map(\.registrations) == [2, 2, 2, 2])
        for source in fixture.sources {
            source.send(source.changeID, registration: 0)
            source.send(source.changeID, registration: 1)
        }
        try await waitForMainActorCondition {
            fixture.changes == [1, 1, 1, 1]
                && fixture.operations.allSatisfy { $0.starts == 2 }
        }
    }

    @MainActor
    @Test func appRuntimeReleaseCancelsObservationsWithoutRetainingOwner() async throws {
        let fixture = RuntimeFixture()
        var runtime: AppRuntimeCoordinator? = fixture.makeRuntime()
        let isReleased = { [weak runtime] in runtime == nil }
        runtime?.start()
        try await waitForMainActorCondition { fixture.operations.allSatisfy { $0.starts == 1 } }

        runtime = nil

        #expect(isReleased())
        try await waitForMainActorCondition {
            fixture.sources.allSatisfy { $0.terminations == 1 }
                && fixture.operations.allSatisfy { $0.cancelledExits == 1 }
        }
        #expect(fixture.events == ["invalidate"])
    }

    @MainActor
    @Test func appRuntimeInstancesKeepTheirEventsIndependent() async throws {
        let first = RuntimeFixture()
        let second = RuntimeFixture()
        let firstRuntime = first.makeRuntime()
        let secondRuntime = second.makeRuntime()
        defer {
            firstRuntime.stop()
            secondRuntime.stop()
        }
        firstRuntime.start()
        secondRuntime.start()
        first.sources[0].send(first.sources[0].changeID)
        second.sources[1].send(second.sources[1].changeID)

        try await waitForMainActorCondition { first.changes[0] == 1 && second.changes[1] == 1 }

        #expect(first.changes == [1, 0, 0, 0])
        #expect(second.changes == [0, 1, 0, 0])
    }

    @MainActor
    @Test func appRuntimeInitialAndRepeatedPhasesPreserveForegroundAndInactiveSemantics() async throws {
        let fixture = RuntimeFixture()
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }
        #expect(!runtime.transition(to: .active))
        runtime.start()

        #expect(runtime.transition(to: .active))
        #expect(!runtime.transition(to: .active))
        try await waitForMainActorCondition { fixture.events == ["foreground", "refresh"] }
        #expect(runtime.transition(to: .inactive))
        #expect(!runtime.transition(to: .inactive))
        #expect(fixture.events == ["foreground", "refresh"])
        fixture.sources[0].send(fixture.sources[0].changeID)
        try await waitForMainActorCondition { fixture.changes[0] == 1 }

        #expect(runtime.transition(to: .active))
        try await waitForMainActorCondition {
            fixture.events == ["foreground", "refresh", "foreground", "refresh"]
        }
        #expect(runtime.transition(to: .background))
        #expect(!runtime.transition(to: .background))
        #expect(fixture.events == ["foreground", "refresh", "foreground", "refresh", "invalidate", "background"])
        fixture.sources[0].send(fixture.sources[0].changeID)
        try await waitForMainActorCondition { fixture.changes[0] == 2 }
    }

    @MainActor
    @Test func appRuntimeInactiveDiscardsForegroundRefreshThatHasNotStarted() async throws {
        let fixture = RuntimeFixture()
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }
        runtime.start()
        runtime.transition(to: .active)
        runtime.transition(to: .inactive)
        fixture.sources[0].send(fixture.sources[0].changeID)

        try await waitForMainActorCondition {
            fixture.changes[0] == 1 && fixture.operations.allSatisfy { $0.starts == 1 }
        }
        #expect(fixture.events == ["foreground"])
        runtime.transition(to: .active)
        try await waitForMainActorCondition { fixture.events.last == "refresh" }
        #expect(fixture.events == ["foreground", "foreground", "refresh"])
    }

    @MainActor
    @Test func appRuntimeInactiveDoesNotCancelRefreshThatHasAlreadyStarted() async throws {
        let fixture = RuntimeFixture()
        fixture.suspendsRefresh = true
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }
        runtime.start()
        runtime.transition(to: .active)
        try await waitForMainActorCondition { fixture.refreshContinuations.count == 1 }

        runtime.transition(to: .inactive)
        fixture.resumeRefresh(at: 0)

        try await waitForMainActorCondition { fixture.refreshCancellations == [false] }
        #expect(fixture.events == ["foreground", "refresh"])
    }

    @MainActor
    @Test func appRuntimeRapidBackgroundPreventsPendingForegroundRefresh() async throws {
        let fixture = RuntimeFixture()
        let runtime = fixture.makeRuntime()
        runtime.start()
        runtime.transition(to: .active)
        runtime.transition(to: .background)
        #expect(fixture.events == ["foreground", "invalidate", "background"])

        // The following active phase supplies a completion barrier for pending tasks.
        runtime.transition(to: .active)
        try await waitForMainActorCondition { fixture.events.last == "refresh" }
        #expect(fixture.events == ["foreground", "invalidate", "background", "foreground", "refresh"])
        runtime.stop()
    }

    @MainActor
    @Test func appRuntimeBackgroundCancelsSuspendedRefreshWithoutCancellingNewPhase() async throws {
        let fixture = RuntimeFixture()
        fixture.suspendsRefresh = true
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }
        runtime.start()
        runtime.transition(to: .active)
        try await waitForMainActorCondition { fixture.refreshContinuations.count == 1 }
        runtime.transition(to: .background)
        #expect(fixture.events == ["foreground", "refresh", "invalidate", "background"])
        runtime.transition(to: .active)
        try await waitForMainActorCondition { fixture.refreshContinuations.count == 2 }

        fixture.resumeRefresh(at: 0)
        try await waitForMainActorCondition { fixture.refreshCancellations == [true] }
        runtime.stop()
        fixture.resumeRefresh(at: 1)
        try await waitForMainActorCondition { fixture.refreshCancellations == [true, true] }
        #expect(fixture.events == ["foreground", "refresh", "invalidate", "background", "foreground", "refresh", "invalidate"])
    }

    @MainActor
    @Test func appRuntimeRestartClearsPreviousLifecyclePhase() async throws {
        let fixture = RuntimeFixture()
        let runtime = fixture.makeRuntime()
        defer { runtime.stop() }
        runtime.start()
        runtime.transition(to: .active)
        runtime.stop()
        #expect(!runtime.transition(to: .background))
        runtime.start()
        #expect(runtime.transition(to: .active))
        try await waitForMainActorCondition { fixture.events.last == "refresh" }
        #expect(fixture.events == ["foreground", "invalidate", "foreground", "refresh"])
    }
}

@MainActor
private final class RuntimeFixture {
    let sources = (0..<4).map { RuntimeStreamSource(changeID: "store-\($0)") }
    let operations = [RuntimeObservationOperation(), RuntimeObservationOperation()]
    var changes = [0, 0, 0, 0]
    var events: [String] = []
    var suspendsRefresh = false
    var refreshContinuations: [CheckedContinuation<Void, Never>?] = []
    var refreshCancellations: [Bool] = []

    func makeRuntime() -> AppRuntimeCoordinator {
        AppRuntimeCoordinator(
            observations: sources.enumerated().map { index, source in
                AppRuntimeCoordinator.StoreObservation(
                    changeID: source.changeID,
                    changes: { source.stream() },
                    onChange: { self.changes[index] += 1 }
                )
            },
            operations: operations.map { operation in { await operation.observe() } },
            actions: AppRuntimeCoordinator.Actions(
                synchronizeForeground: { self.events.append("foreground") },
                refreshUnread: {
                    self.events.append("refresh")
                    if self.suspendsRefresh {
                        await withCheckedContinuation { self.refreshContinuations.append($0) }
                        self.refreshCancellations.append(Task.isCancelled)
                    }
                },
                invalidateUnread: { self.events.append("invalidate") },
                synchronizeBackground: { self.events.append("background") }
            )
        )
    }

    func resumeRefresh(at index: Int) {
        refreshContinuations[index]?.resume()
        refreshContinuations[index] = nil
    }
}

@MainActor
private final class RuntimeStreamSource {
    let changeID: String
    private var continuations: [AsyncStream<String>.Continuation] = []
    var registrations: Int { continuations.count }
    var terminations = 0

    init(changeID: String) { self.changeID = changeID }

    func stream() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.terminations += 1 }
        }
        continuations.append(continuation)
        return stream
    }

    func send(_ value: String, registration: Int = 0) {
        continuations[registration].yield(value)
    }
}

@MainActor
private final class RuntimeObservationOperation {
    var starts = 0
    var cancelledExits = 0

    func observe() async {
        starts += 1
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        for await _ in stream {}
        if Task.isCancelled { cancelledExits += 1 }
        continuation.finish()
    }
}
