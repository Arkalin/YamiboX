import Foundation
import Observation
import YamiboXCore

struct NetworkLogExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
@Observable
final class NetworkLogViewModel {
    private(set) var entries: [NetworkLogEntry] = []
    private(set) var hasLoaded = false
    private(set) var isWorking = false
    var exportFile: NetworkLogExportFile?
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?

    private let store: NetworkLogStore
    private var refreshGeneration = 0
    private var exportURL: URL?
    private var shareError: Error?

    init(store: NetworkLogStore) {
        self.store = store
    }

    func observeChanges() async {
        let changes = await store.changes()
        let clock = ContinuousClock()
        var lastRefresh: ContinuousClock.Instant?
        for await _ in changes {
            guard !Task.isCancelled else { return }
            if let lastRefresh {
                do {
                    try await clock.sleep(until: lastRefresh.advanced(by: .milliseconds(250)))
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            // The stream keeps only its newest event while bursts of image
            // completions are coalesced, without delaying explicit refreshes.
            lastRefresh = clock.now
            await refresh()
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let snapshot = try await store.entries()
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            entries = snapshot
            hasLoaded = true
        } catch {
            guard generation == refreshGeneration else { return }
            hasLoaded = true
            showError(error)
        }
    }

    func export() async {
        guard !isWorking, !entries.isEmpty, exportFile == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await store.export()
            if Task.isCancelled {
                await store.removeExport(at: url)
                return
            }
            exportURL = url
            exportFile = NetworkLogExportFile(url: url)
        } catch {
            showError(error)
        }
    }

    func clear() async {
        guard !isWorking else { return }
        isWorking = true
        refreshGeneration += 1
        defer { isWorking = false }
        do {
            try await store.clear()
            await refresh()
        } catch {
            showError(error)
        }
    }

    func finishExport() {
        exportFile = nil
        if let url = exportURL {
            exportURL = nil
            Task { await store.removeExport(at: url) }
        }
        if let error = shareError {
            shareError = nil
            showError(error)
        }
    }

    func sharingDidFinish(error: Error?) {
        shareError = error
        exportFile = nil
    }

    private func showError(_ error: Error) {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
    }
}
