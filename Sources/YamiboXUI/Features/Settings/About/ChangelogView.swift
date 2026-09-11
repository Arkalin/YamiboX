import Observation
import SwiftUI
import YamiboXCore

struct ChangelogView: View {
    @State private var viewModel = ChangelogViewModel()
    @State private var loadAttempt = 0

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView(L10n.string("common.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(versions):
                if versions.isEmpty {
                    ContentUnavailableView(
                        L10n.string("changelog.empty"), systemImage: "doc.text"
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(versions, id: \.version) { version in
                                ChangelogVersionSection(version: version)
                            }
                        }
                        .padding(24)
                    }
                }
            case let .failed(details):
                LoadFailureView(message: details.summary, details: details) {
                    loadAttempt += 1
                }
            }
        }
        .navigationTitle(L10n.string("about.changelog"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: loadAttempt) {
            await viewModel.load()
        }
    }
}

private struct ChangelogVersionSection: View {
    let version: AppSourceVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("about.version", version.version))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if let date = displayDate {
                Text(date, format: .dateTime.year().month().day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(description)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
        }
    }

    private var description: String {
        let notes = version.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? L10n.string("changelog.no_description") : notes
    }

    private var displayDate: Date? {
        guard let date = version.date else { return nil }
        return (try? Date(date, strategy: .iso8601))
            ?? (try? Date(date, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(date, strategy: Date.ISO8601FormatStyle().year().month().day()))
    }
}

@MainActor
@Observable
final class ChangelogViewModel {
    enum State {
        case idle
        case loading
        case loaded([AppSourceVersion])
        case failed(LoadFailureDetails)
    }

    private(set) var state: State = .idle
    private let loadVersions: @Sendable () async throws -> [AppSourceVersion]

    init(loadVersions: (@Sendable () async throws -> [AppSourceVersion])? = nil) {
        self.loadVersions = loadVersions ?? {
            try await AppChangelogLoader().load()
        }
    }

    func load() async {
        if case .loading = state { return }
        state = .loading
        do {
            let versions = try await loadVersions()
            try Task.checkCancellation()
            state = .loaded(versions)
        } catch {
            if Task.isCancelled || LoadDiagnosticError.isCancellation(error) {
                state = .idle
            } else {
                state = .failed(LoadFailureDetails(error: error))
            }
        }
    }
}
