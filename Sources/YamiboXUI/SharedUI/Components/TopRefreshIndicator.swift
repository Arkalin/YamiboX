import SwiftUI

private struct PullRefreshIndicatorModifier: ViewModifier {
    let isVisible: Bool
    let refresh: @MainActor @Sendable () async -> Void

    @State private var isPullRefreshing = false

    func body(content: Content) -> some View {
        content
            .refreshable {
                guard !isPullRefreshing else { return }
                isPullRefreshing = true
                defer { isPullRefreshing = false }
                await refresh()
            }
            .topRefreshIndicator(isVisible: isVisible && !isPullRefreshing)
    }
}

extension View {
    func topRefreshIndicator(isVisible: Bool) -> some View {
        overlay(alignment: .top) {
            if isVisible {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
    }

    /// Uses the native spinner for pull-to-refresh and a top overlay for
    /// refreshes started elsewhere, never displaying both at once.
    func refreshableWithTopIndicator(
        isRefreshing: Bool,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        modifier(PullRefreshIndicatorModifier(isVisible: isRefreshing, refresh: action))
    }
}
