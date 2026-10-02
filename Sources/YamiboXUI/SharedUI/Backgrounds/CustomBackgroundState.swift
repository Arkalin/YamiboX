import Foundation
import Observation
import YamiboXCore

/// Independently observed background state. A late file read must not replace
/// the image chosen by a newer settings update.
@MainActor
@Observable
public final class CustomBackgroundState {
    public private(set) var settings = CustomBackgroundSettings()
    public private(set) var imageData: Data?
    public private(set) var showsOverlay = true
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let imageStore: CustomBackgroundImageStore
    @ObservationIgnored private let scope: CustomBackgroundImageStore.Scope
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(settingsStore: SettingsStore, imageStore: CustomBackgroundImageStore, scope: CustomBackgroundImageStore.Scope,
                initialOverlayVisibility: Bool = true) {
        showsOverlay = initialOverlayVisibility
        self.scope = scope
        self.settingsStore = settingsStore
        self.imageStore = imageStore
        observationTask = StoreChangeObservation.task(
            changes: { settingsStore.changes() }, changeID: { settingsStore.changeID }
        ) { [weak self] in
            await self?.reload()
        }
    }

    deinit { observationTask?.cancel() }

    public func reload() async {
        revision &+= 1
        let request = revision
        let snapshot = await settingsStore.load()
        var settings = switch scope {
        case .favorites: snapshot.favorites.background
        case .launch: snapshot.appearance.launchBackground
        case .bookshelf: snapshot.system.bookshelfBackground
        }
        if scope == .launch { settings.blurRadius = 0 }
        let showsOverlay = scope == .launch ? snapshot.appearance.launchShowsBrand : true
        let imageChanged = !hasLoaded || settings != self.settings
        guard !Task.isCancelled, revision == request,
              imageChanged || showsOverlay != self.showsOverlay else { return }
        let data = imageChanged ? await imageStore.loadData(imageID: settings.imageID) : imageData
        guard !Task.isCancelled, revision == request else { return }
        self.settings = settings
        imageData = data
        self.showsOverlay = showsOverlay
        hasLoaded = true
    }
}
