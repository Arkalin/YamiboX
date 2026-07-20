import Foundation
import YamiboXCore

extension AppSourceVersion {
    /// Alert body shared by the launch prompt and the About page's manual
    /// check: version line, then package size, then release notes.
    var updateAvailableAlertMessage: String {
        var parts = [
            L10n.string("app_update.available_message", version)
        ]
        if let size, size > 0 {
            parts.append(L10n.string("app_update.size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let localizedDescription, !localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(localizedDescription)
        }
        return parts.joined(separator: "\n\n")
    }
}

struct AppUpdateLaunchPrompt: Equatable {
    let version: AppSourceVersion

    var title: String { L10n.string("app_update.available_title") }
    var message: String { version.updateAvailableAlertMessage }
    var downloadURL: URL { version.downloadURL }
}

/// Launch-time update prompt: checks the app source once per launch and
/// surfaces an alert only when it advertises a version newer than the
/// running app. Failures and up-to-date results stay silent — the About
/// page's manual check is the surface that reports those.
@MainActor
@Observable
final class AppUpdateLaunchPrompter {
    typealias CheckForUpdate = @Sendable () async -> AppUpdateCheckResult

    private(set) var prompt: AppUpdateLaunchPrompt?

    @ObservationIgnored private var hasChecked = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let checkForUpdate: CheckForUpdate

    init(
        defaults: UserDefaults = .standard,
        checkForUpdate: @escaping CheckForUpdate = {
            await AppUpdateChecker().checkForUpdate(
                currentBundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            )
        }
    ) {
        self.defaults = defaults
        self.checkForUpdate = checkForUpdate
    }

    func checkForUpdateIfNeeded() async {
        guard !hasChecked else { return }
        hasChecked = true

        guard case let .updateAvailable(version) = await checkForUpdate() else { return }
        guard version.version != defaults.string(forKey: YamiboAppStorageKey.appUpdateSkippedVersion) else { return }
        prompt = AppUpdateLaunchPrompt(version: version)
    }

    /// Suppresses future launch prompts for exactly the prompted version;
    /// a later release prompts again.
    func skipPromptedVersion() {
        if let prompt {
            defaults.set(prompt.version.version, forKey: YamiboAppStorageKey.appUpdateSkippedVersion)
        }
        prompt = nil
    }

    func dismissPrompt() {
        prompt = nil
    }
}
