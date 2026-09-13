import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

struct ReaderFailureDetailsFixture: View {
    @State private var isReaderPresented = false

    var body: some View {
        Button("Open failure reader") { isReaderPresented = true }
            .accessibilityIdentifier("failure-fixture-open")
            .fullScreenCover(isPresented: $isReaderPresented) {
                ReaderFailureDetailsFixtureScreen()
            }
    }
}

private struct ReaderFailureDetailsFixtureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 1
    @State private var isLoading = false
    @State private var scheduledRetry: Task<Void, Never>?

    private var status: ReaderLoadStateStatus {
        if isLoading { return .loading }
        return .failed(title: "Fixture image failure", message: "Timed out loading image",
            details: LoadFailureDetails(error: URLError(.timedOut),
                requestContext: "https://image-fixture.invalid/page-\(attempt).png"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(isLoading ? "Loading retry" : "Failed attempt \(attempt)")
                    .accessibilityIdentifier("failure-fixture-status")
                HStack {
                    Button("Retry after delay") {
                        scheduledRetry?.cancel()
                        scheduledRetry = Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }
                            isLoading = true
                        }
                    }
                    .accessibilityIdentifier("failure-fixture-delayed-retry")
                    Button("Fail again") {
                        attempt += 1
                        isLoading = false
                    }
                    .accessibilityIdentifier("failure-fixture-fail-again")
                }
                ReaderFailureConfigurationSurface(status: status, retry: { isLoading = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Reader failure fixture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close reader") { dismiss() }
                        .accessibilityIdentifier("failure-fixture-close-reader")
                }
            }
        }
        .onDisappear { scheduledRetry?.cancel() }
    }
}

/// A hosting configuration has no presentation controller of its own, just
/// like the nested spread content inside the manga reader's UIKit surface.
private struct ReaderFailureConfigurationSurface: UIViewRepresentable {
    let status: ReaderLoadStateStatus
    let retry: () -> Void

    final class Coordinator {
        var hostedView: (UIView & UIContentView)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let hosted = configuration.makeContentView()
        context.coordinator.hostedView = hosted
        hosted.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.hostedView?.configuration = configuration
    }

    private var configuration: some UIContentConfiguration {
        UIHostingConfiguration {
            HStack(spacing: 0) {
                ReaderLoadStateView(status: status, retryAction: retry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color(uiColor: .secondarySystemBackground)
                    .overlay { Text("Adjacent manga page") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .margins(.all, 0)
    }
}
