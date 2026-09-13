import SwiftUI
import XCTest
@testable import YamiboXUI

@MainActor
final class TopRefreshIndicatorTests: XCTestCase {
    func testPullRefreshSuppressesOverlayAndRestoresBackgroundIndicator() async throws {
        let state = RefreshIndicatorFixtureState()
        let host = UIHostingController(rootView: RefreshIndicatorFixture(state: state))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.keyWindow
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer {
            state.pendingRefresh?.resume()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        await waitFor { state.action != nil && self.overlaySpinnerCount(in: host.view) == 1 }
        let action = try XCTUnwrap(state.action)

        // Exercise the installed refresh action twice to catch stale local state.
        for _ in 0..<2 {
            let task = Task { await action() }
            await waitFor { state.pendingRefresh != nil }
            await waitFor { self.overlaySpinnerCount(in: host.view) == 0 }
            state.pendingRefresh?.resume()
            state.pendingRefresh = nil
            await task.value
            await waitFor { self.overlaySpinnerCount(in: host.view) == 1 }
        }

        state.isRefreshing = false
        await waitFor { self.overlaySpinnerCount(in: host.view) == 0 }
    }

    private func overlaySpinnerCount(in view: UIView) -> Int {
        // The native pull indicator belongs to UIRefreshControl, not our overlay.
        if view is UIRefreshControl { return 0 }
        return (view is UIActivityIndicatorView ? 1 : 0)
            + view.subviews.reduce(0) { $0 + overlaySpinnerCount(in: $1) }
    }

    private func waitFor(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
@Observable
private final class RefreshIndicatorFixtureState {
    var isRefreshing = true
    var action: RefreshAction?
    var pendingRefresh: CheckedContinuation<Void, Never>?

    func refresh() async {
        await withCheckedContinuation { pendingRefresh = $0 }
    }
}

private struct RefreshIndicatorFixture: View {
    let state: RefreshIndicatorFixtureState

    var body: some View {
        ScrollView {
            Text("Content")
        }
        .background {
            RefreshActionProbe(state: state)
        }
        .refreshableWithTopIndicator(isRefreshing: state.isRefreshing) {
            await state.refresh()
        }
    }
}

private struct RefreshActionProbe: View {
    @Environment(\.refresh) private var refresh
    let state: RefreshIndicatorFixtureState

    var body: some View {
        Color.clear
            .task { state.action = refresh }
    }
}
