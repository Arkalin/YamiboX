import Observation
import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

struct SettingsSidebarAppearanceFixture: View {
    @State private var model = SettingsSidebarAppearanceFixtureModel()
    @State private var path: [String] = []
    @State private var selection: SettingsSidebarDestination? = .category(.general)
    private let environment = ProcessInfo.processInfo.environment

    private var isCompact: Bool { environment["SETTINGS_SIDEBAR_APPEARANCE_COMPACT"] == "1" }
    private var isDark: Bool { environment["SETTINGS_SIDEBAR_APPEARANCE_DARK"] == "1" }

    var body: some View {
        SettingsSidebarTraitHost(content: navigation, isCompact: isCompact, isDark: isDark)
            .frame(width: 375)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(isDark ? .dark : .light)
            .task { await model.load() }
    }

    private var navigation: some View {
        NavigationStack(path: $path) {
            List {
                if model.isLoaded {
                    Button("设置") { path = ["settings"] }
                        .accessibilityIdentifier("settings.appearance.open")
                } else if let error = model.error {
                    Text(error).accessibilityIdentifier("settings.appearance.error")
                } else {
                    ProgressView()
                }
            }
            .sidebarListSurface(isCompact: isCompact)
            .navigationTitle("Mine")
            .navigationDestination(for: String.self) { _ in
                SettingsSidebar(
                    viewModel: model.viewModel,
                    selection: $selection,
                    accountManagementAvailable: false,
                    isSigningOut: false,
                    aboutTitle: "About",
                    showsCloseButton: false,
                    onSignOut: {},
                    onClose: {},
                    usesSelectionButtons: true,
                    usesCompactLayout: isCompact
                )
            }
        }
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

/// UIKit-backed list cells need the same traits as the SwiftUI sidebar policy.
private struct SettingsSidebarTraitHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let isCompact: Bool
    let isDark: Bool

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        applyTraits(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        applyTraits(to: controller)
        controller.rootView = content
    }

    private func applyTraits(to controller: UIHostingController<Content>) {
        controller.traitOverrides.horizontalSizeClass = isCompact ? .compact : .regular
        controller.overrideUserInterfaceStyle = isDark ? .dark : .light
    }
}

@MainActor @Observable
private final class SettingsSidebarAppearanceFixtureModel {
    let context: YamiboAppContext
    let viewModel: SystemSettingsViewModel
    var isLoaded = false
    var error: String?

    init() {
        let suite = "settings-sidebar-appearance-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: UserDefaults(suiteName: suite)!),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
            grdbRootDirectory: root,
            cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: suite)!,
            clearsWebDataOnReset: false
        )
        viewModel = SystemSettingsViewModel(dependencies: context.settingsDependencies)
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            try await context.settingsDependencies.sessionStore.save(SessionState(
                cookie: "\(SessionState.authenticationCookieName)=appearance-fixture",
                isLoggedIn: true
            ))
            await viewModel.refreshSessionState()
            isLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
