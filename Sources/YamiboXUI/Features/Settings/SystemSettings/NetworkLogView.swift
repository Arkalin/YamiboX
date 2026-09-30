import SwiftUI
import UIKit
import YamiboXCore

struct NetworkLogView: View {
    @State private var viewModel: NetworkLogViewModel
    @State private var showingClearConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    init(store: NetworkLogStore) {
        _viewModel = State(initialValue: NetworkLogViewModel(store: store))
    }

    var body: some View {
        List {
            Section {
                if viewModel.entries.isEmpty {
                    if viewModel.hasLoaded {
                        ContentUnavailableView(
                            L10n.string("settings.network_log.empty_title"),
                            systemImage: "network",
                            description: Text(L10n.string("settings.network_log.empty_message"))
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ProgressView(L10n.string("common.loading"))
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(viewModel.entries) { entry in
                        NavigationLink {
                            NetworkLogDetailView(entry: entry)
                        } label: {
                            NetworkLogRow(entry: entry)
                        }
                    }
                }
            } header: {
                Text(L10n.string("settings.network_log.record_count", viewModel.entries.count))
            }
        }
        .navigationTitle(L10n.string("settings.network_log.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.observeChanges() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await viewModel.refresh()
        }
        .refreshable { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await viewModel.export() }
                    } label: {
                        Label(L10n.string("settings.network_log.export"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.entries.isEmpty || viewModel.isWorking || viewModel.exportFile != nil)
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label(L10n.string("common.clear_all"), systemImage: "trash")
                    }
                    .disabled(viewModel.isWorking)
                } label: {
                    Label(L10n.string("common.more"), systemImage: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if viewModel.isWorking {
                ProgressView(L10n.string("common.loading"))
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $viewModel.exportFile, onDismiss: viewModel.finishExport) { exportFile in
            NetworkLogShareSheet(url: exportFile.url) { error in
                viewModel.sharingDidFinish(error: error)
            }
            .presentationDetents([.medium, .large])
        }
        .alert(L10n.string("settings.network_log.clear_title"), isPresented: $showingClearConfirmation) {
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(L10n.string("common.clear_all"), role: .destructive) {
                Task { await viewModel.clear() }
            }
        } message: {
            Text(L10n.string("settings.network_log.clear_message"))
        }
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: .presentation(
                isPresented: { viewModel.errorMessage != nil },
                clearOnDismiss: { viewModel.errorMessage = nil }
            )
        ) {
            Button(L10n.string("common.ok")) { viewModel.errorMessage = nil }
        }
    }
}

private struct NetworkLogRow: View {
    let entry: NetworkLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.method).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(NetworkLogPresentation.status(entry)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.method).fontWeight(.semibold)
                    Text(NetworkLogPresentation.status(entry)).foregroundStyle(.secondary)
                }
            }
            Text(entry.initialURL)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(entry.startedAt, format: .dateTime.month().day().hour().minute().second())
                    Spacer(minLength: 8)
                    Text(NetworkLogPresentation.duration(entry.duration))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.startedAt, format: .dateTime.month().day().hour().minute().second())
                    Text(NetworkLogPresentation.duration(entry.duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct NetworkLogDetailView: View {
    let entry: NetworkLogEntry

    var body: some View {
        Form {
            NetworkLogSummarySection(entry: entry)
            NetworkLogURLSection(initialURL: entry.initialURL, finalURL: entry.finalURL)
            NetworkLogTransferSection(sentBytes: entry.sentBytes, receivedBytes: entry.receivedBytes)
            if !entry.redirects.isEmpty {
                NetworkLogRedirectSection(redirects: entry.redirects)
            }
            if let error = entry.error {
                Section(L10n.string("settings.network_log.error")) {
                    NetworkLogTextField(title: L10n.string("settings.network_log.error_category"), value: error.category)
                    LabeledContent(L10n.string("settings.network_log.error_code"), value: String(error.code))
                }
            }
            Section {
                NetworkLogTextField(title: L10n.string("settings.network_log.id"), value: entry.id.uuidString)
                LabeledContent(L10n.string("settings.network_log.format_version"), value: String(entry.formatVersion))
            } footer: {
                if entry.truncated {
                    Text(L10n.string("settings.network_log.truncated"))
                }
            }
        }
        .navigationTitle(L10n.string("settings.network_log.details"))
        .navigationBarTitleDisplayMode(.inline)
        .textSelection(.enabled)
    }
}

private struct NetworkLogSummarySection: View {
    let entry: NetworkLogEntry

    var body: some View {
        Section(L10n.string("settings.network_log.summary")) {
            LabeledContent(L10n.string("settings.network_log.started_at")) {
                Text(entry.startedAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            LabeledContent(L10n.string("settings.network_log.source"), value: NetworkLogPresentation.source(entry.source))
            LabeledContent(L10n.string("settings.network_log.method"), value: entry.method)
            LabeledContent(L10n.string("settings.network_log.status"), value: NetworkLogPresentation.status(entry))
            LabeledContent(L10n.string("settings.network_log.duration"), value: NetworkLogPresentation.duration(entry.duration))
        }
    }
}

private struct NetworkLogURLSection: View {
    let initialURL: String
    let finalURL: String?

    var body: some View {
        Section(L10n.string("settings.network_log.urls")) {
            NetworkLogTextField(title: L10n.string("settings.network_log.initial_url"), value: initialURL)
            NetworkLogTextField(
                title: L10n.string("settings.network_log.final_url"),
                value: finalURL ?? L10n.string("settings.network_log.unknown")
            )
        }
    }
}

private struct NetworkLogTransferSection: View {
    let sentBytes: Int64?
    let receivedBytes: Int64?

    var body: some View {
        Section(L10n.string("settings.network_log.transfer")) {
            LabeledContent(L10n.string("settings.network_log.sent_bytes"), value: NetworkLogPresentation.bytes(sentBytes))
            LabeledContent(L10n.string("settings.network_log.received_bytes"), value: NetworkLogPresentation.bytes(receivedBytes))
        }
    }
}

private struct NetworkLogRedirectSection: View {
    let redirects: [NetworkLogRedirect]

    var body: some View {
        Section(L10n.string("settings.network_log.redirects")) {
            ForEach(Array(redirects.enumerated()), id: \.offset) { index, redirect in
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("settings.network_log.redirect_number", index + 1))
                        .font(.headline)
                    NetworkLogTextField(
                        title: L10n.string("settings.network_log.initial_url"),
                        value: redirect.fromURL ?? L10n.string("settings.network_log.unknown")
                    )
                    NetworkLogTextField(
                        title: L10n.string("settings.network_log.final_url"),
                        value: redirect.toURL ?? L10n.string("settings.network_log.unknown")
                    )
                    LabeledContent(
                        L10n.string("settings.network_log.status"),
                        value: redirect.statusCode.map(String.init) ?? L10n.string("settings.network_log.unknown")
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct NetworkLogTextField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum NetworkLogPresentation {
    static func source(_ source: NetworkLogSource) -> String {
        L10n.string("settings.network_log.source.\(source.rawValue)")
    }

    static func status(_ entry: NetworkLogEntry) -> String {
        if let error = entry.error {
            let cancelled = (error.category == NSURLErrorDomain && error.code == NSURLErrorCancelled)
                || error.category == "Swift.CancellationError"
            let errorStatus = cancelled
                ? L10n.string("settings.network_log.cancelled")
                : L10n.string("settings.network_log.failed")
            if let statusCode = entry.statusCode {
                return "HTTP \(statusCode) · \(errorStatus)"
            }
            return errorStatus
        }
        return entry.statusCode.map { "HTTP \($0)" } ?? L10n.string("settings.network_log.unknown")
    }

    static func duration(_ duration: TimeInterval) -> String {
        L10n.string("settings.network_log.duration_value", duration)
    }

    static func bytes(_ bytes: Int64?) -> String {
        bytes.map { L10n.string("settings.network_log.bytes_value", $0) }
            ?? L10n.string("settings.network_log.unknown")
    }
}

private struct NetworkLogShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinished: @MainActor (Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in onFinished(error) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
