import Foundation
import YamiboXCore

/// Shared persistence template for the settings pages: optimistic UI update,
/// persist, and roll back with an error message on failure. This replaces the
/// per-method `let previous` + load-mutate-save-rollback boilerplate the
/// former monolithic view model repeated for every `update*` method.
@MainActor
protocol AppSettingsPersisting: SystemSettingsActivityReporting {
    var dependencies: SettingsDependencies { get }
}

extension AppSettingsPersisting {
    /// Load-mutate-save flavor: writes `value` into the view-model property at
    /// `keyPath` immediately (optimistic UI), then persists in the background.
    ///
    /// `mutate` runs at persist time on the main actor, so closures that read
    /// *live* view-model state (e.g. the favorites page writing all four
    /// display fields at once) see any optimistic values already applied —
    /// exactly like the inlined originals did.
    ///
    /// On failure the property is rolled back only while the optimistic value
    /// is still current: a newer edit the user made while this save was in
    /// flight must not be clobbered by a stale rollback.
    func persistSettings<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Self, Value>,
        to value: Value,
        mutate: @escaping @MainActor (inout AppSettings) -> Void
    ) {
        let previous = self[keyPath: keyPath]
        self[keyPath: keyPath] = value

        Task {
            var settings = await dependencies.settingsStore.load()
            mutate(&settings)

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                if self[keyPath: keyPath] == value {
                    self[keyPath: keyPath] = previous
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Atomic flavor: persists through `SettingsStore.update`, whose
    /// read-modify-write runs inside the store's actor as one uninterruptible
    /// step. Used for fields that other screens also write (e.g. the favorite
    /// quick-action prompts' "remember" variants persist the same sync
    /// switches), where a whole-blob load/save from this page could clobber a
    /// concurrent writer. Rollback is unconditional, matching the historical
    /// semantics of the sync-behavior toggles this template was lifted from.
    func persistSettingsAtomically<Value>(
        _ keyPath: ReferenceWritableKeyPath<Self, Value>,
        to value: Value,
        mutate: @escaping @Sendable (inout AppSettings) -> Void
    ) {
        let previous = self[keyPath: keyPath]
        self[keyPath: keyPath] = value

        Task {
            do {
                _ = try await dependencies.settingsStore.update(mutate)
            } catch {
                self[keyPath: keyPath] = previous
                errorMessage = error.localizedDescription
            }
        }
    }
}
