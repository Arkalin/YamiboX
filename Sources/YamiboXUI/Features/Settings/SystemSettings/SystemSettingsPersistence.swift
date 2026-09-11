import Foundation
import YamiboXCore

typealias AtomicSettingsUpdater = @Sendable (
    _ mutate: @Sendable (inout AppSettings) -> Void
) async throws -> AppSettings

/// Optimistic presentation backed by atomic, field-level settings mutations.
@MainActor
protocol AppSettingsPersisting: SystemSettingsActivityReporting {
    var dependencies: SettingsDependencies { get }
}

extension AppSettingsPersisting {
    /// Capture the edited fields before calling; the mutation executes inside
    /// SettingsStore, without suspending between reading and writing.
    @discardableResult
    func persistSettings<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Self, Value>,
        to value: Value,
        updateSettings: AtomicSettingsUpdater? = nil,
        mutate: @escaping @Sendable (inout AppSettings) -> Void
    ) -> Task<Bool, Never> {
        let previous = self[keyPath: keyPath]
        let editID = activity.beginSettingsEdit(owner: self, keyPath: keyPath) { [weak self] in
            guard let self, self[keyPath: keyPath] == value else { return false }
            self[keyPath: keyPath] = previous
            return true
        }
        self[keyPath: keyPath] = value

        return Task {
            var succeeded = false
            defer {
                activity.finishSettingsEdit(owner: self, keyPath: keyPath, editID: editID, succeeded: succeeded)
            }
            do {
                if let updateSettings {
                    _ = try await updateSettings(mutate)
                } else {
                    _ = try await dependencies.settingsStore.update(mutate)
                }
                succeeded = true
                return true
            } catch {
                if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                    errorMessage = error.localizedDescription
                    errorDetails = LoadFailureDetails(error: error)
                }
                return false
            }
        }
    }
}
