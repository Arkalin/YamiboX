import Foundation

/// One instance per destination. Serializes file + settings commits across windows,
/// so pruning cannot remove an image another in-flight editor just committed.
public actor CustomBackgroundPersistence {
    private let settingsStore: SettingsStore
    private let imageStore: CustomBackgroundImageStore
    private let scope: CustomBackgroundImageStore.Scope
    private var pending: Task<CustomBackgroundSettings, any Error>?

    public init(settingsStore: SettingsStore, imageStore: CustomBackgroundImageStore, scope: CustomBackgroundImageStore.Scope) {
        self.settingsStore = settingsStore
        self.imageStore = imageStore
        self.scope = scope
    }

    public func apply(imageData: Data?, settings: CustomBackgroundSettings, overlayVisibility: Bool? = nil) async throws -> CustomBackgroundSettings {
        let previous = pending
        let task = Task { [settingsStore, imageStore, scope] in
            _ = try? await previous?.value
            let imageID = imageData.map { _ in UUID().uuidString }
            let updated = imageID.map {
                CustomBackgroundSettings(isEnabled: true, imageID: $0, scale: settings.scale,
                                         offsetX: settings.offsetX, offsetY: settings.offsetY,
                                         blurRadius: scope == .launch ? 0 : settings.blurRadius)
            } ?? .init()
            do {
                if let imageData, let imageID { try await imageStore.save(imageData, imageID: imageID) }
                try await settingsStore.update {
                    switch scope {
                    case .favorites: $0.favorites.background = updated
                    case .launch:
                        $0.appearance.launchBackground = updated
                        if let overlayVisibility { $0.appearance.launchShowsBrand = overlayVisibility }
                    }
                }
            } catch {
                try? await imageStore.delete(imageID: imageID)
                throw error
            }
            // Cleanup failure must not roll back a successfully committed setting.
            do { try await imageStore.prune(keeping: imageID) }
            catch { YamiboLog.persistence.warning("Failed to prune custom background images: \(error)") }
            return updated
        }
        pending = task
        return try await task.value
    }
}
