import Foundation
import Observation
import YamiboXCore

/// Independently observed background state. A late file read must not replace
/// the image chosen by a newer settings update.
@MainActor
@Observable
final class FavoriteBackgroundState {
    private(set) var settings = FavoriteBackgroundSettings()
    private(set) var imageData: Data?
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let imageStore: FavoriteBackgroundImageStore
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(settingsStore: SettingsStore, imageStore: FavoriteBackgroundImageStore) {
        self.settingsStore = settingsStore
        self.imageStore = imageStore
        observationTask = StoreChangeObservation.task(
            changes: { settingsStore.changes() }, changeID: { settingsStore.changeID }
        ) { [weak self] in
            await self?.reload()
        }
    }

    deinit { observationTask?.cancel() }

    func reload() async {
        revision &+= 1
        let request = revision
        let settings = await settingsStore.load().favorites.background
        guard !Task.isCancelled, revision == request,
              !hasLoaded || settings != self.settings else { return }
        let data = await imageStore.loadData(imageID: settings.imageID)
        guard !Task.isCancelled, revision == request else { return }
        self.settings = settings
        imageData = data
        hasLoaded = true
    }
}
