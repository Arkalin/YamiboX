import SwiftUI
import YamiboXCore

/// Root settings screen: search plus entries into the five settings
/// categories. Pushed onto the Mine tab's navigation stack (not a sheet),
/// so it owns no `NavigationStack` of its own.
public struct SettingsHomeView: View {
    private let dependencies: SettingsDependencies
    private let peripheralInput: ReaderPeripheralInputManager?
    private let onSignOut: @MainActor () async -> String?
    private let onApplicationReset: @MainActor () async -> Void
    private let onClose: () -> Void

    /// `@State` (not `@StateObject`) because the view model is `@Observable`.
    /// SwiftUI keeps the first instance for the view's lifetime; the
    /// constructions on later `init` calls are discarded, which is safe here
    /// because `SystemSettingsViewModel.init` only wires objects together and
    /// has no side effects.
    @State private var viewModel: SystemSettingsViewModel
    @State private var searchText = ""
    @State private var pushedCategory: SettingsCategory?
    @State private var isAboutPushed = false
    @State private var pendingConfirmation: SystemSettingsConfirmation?
    @State private var isSigningOut = false

    public init(
        dependencies: SettingsDependencies,
        peripheralInput: ReaderPeripheralInputManager? = nil,
        onSignOut: @escaping @MainActor () async -> String?,
        onApplicationReset: @escaping @MainActor () async -> Void,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SystemSettingsViewModel(dependencies: dependencies))
        self.dependencies = dependencies
        self.peripheralInput = peripheralInput
        self.onSignOut = onSignOut
        self.onApplicationReset = onApplicationReset
        self.onClose = onClose
    }

    public var body: some View {
        List {
            if isSearching {
                searchResultsSection
            } else {
                categorySection
                aboutSection
                if viewModel.isLoggedIn {
                    signOutSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("settings.title"))
        .yamiboInlineNavigationTitleDisplayMode()
        .searchable(text: $searchText, prompt: L10n.string("settings.search.placeholder"))
        .overlay(content: loadingOverlay)
        .task {
            await viewModel.load()
        }
        .navigationDestination(isPresented: $isAboutPushed) {
            AboutView()
        }
        .navigationDestination(item: $pushedCategory) { category in
            categoryView(for: category)
        }
        .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
        .destructiveConfirmationAlert(
            item: $pendingConfirmation,
            title: \.title,
            actionTitle: \.buttonTitle,
            message: \.message
        ) { confirmation in
            Task {
                await handleConfirmation(confirmation)
            }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var categorySection: some View {
        Section {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    pushedCategory = category
                } label: {
                    SettingsCategoryRow(category: category)
                }
                .disabled(viewModel.isBusy)
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Button {
                isAboutPushed = true
            } label: {
                SystemSettingsRow(title: aboutSettingsTitle, titleColor: .accentColor)
            }
            .disabled(viewModel.isBusy)
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                pendingConfirmation = .signOut
            } label: {
                Text(L10n.string("mine.sign_out"))
            }
            .disabled(viewModel.isBusy || isSigningOut)
        }
    }

    /// Every path into a category page — the list above and these search
    /// results — routes through `pushedCategory`, which is only reachable
    /// from this screen. Gating navigation here on `viewModel.isBusy`, not
    /// just each destination's own controls, is what keeps a
    /// still-running action on one page (e.g. Storage) from ever becoming
    /// reachable-but-frozen on another page the user navigates to next, and
    /// keeps Sign Out from firing concurrently with an in-flight action
    /// that shares the same view model and underlying stores.
    private var searchResultsSection: some View {
        let results = SettingsSearchRegistry.search(searchText)
        return Section {
            if results.isEmpty {
                Text(L10n.string("settings.search.no_results"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { entry in
                    Button {
                        pushedCategory = entry.category
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .foregroundStyle(.primary)
                            Text(entry.category.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(viewModel.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryView(for category: SettingsCategory) -> some View {
        switch category {
        case .general:
            SettingsGeneralView(viewModel: viewModel.general)
        case .favorites:
            SettingsFavoritesView(dependencies: dependencies, viewModel: viewModel.favorites)
        case .reading:
            SettingsReadingView(viewModel: viewModel.reading)
        case .peripherals:
            SystemSettingsPeripheralPageTurnView(viewModel: viewModel.peripherals, peripheralInput: peripheralInput)
        case .storage:
            SettingsStorageView(
                dependencies: dependencies,
                viewModel: viewModel.storage,
                offlineCacheManagement: viewModel.offlineCacheManagement,
                mangaDirectoryManagement: viewModel.mangaDirectoryManagement,
                onReset: handleApplicationReset
            )
        }
    }

    @ViewBuilder
    private func loadingOverlay() -> some View {
        if viewModel.isBusy || isSigningOut {
            ProgressView(loadingOverlayTitle)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var loadingOverlayTitle: String {
        isSigningOut ? L10n.string("mine.signing_out") : L10n.string("common.loading")
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
    }


    private var aboutSettingsTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return L10n.string(
            "settings.about_app_with_version",
            version?.isEmpty == false ? version! : "--"
        )
    }

    private func handleConfirmation(_ confirmation: SystemSettingsConfirmation) async {
        guard confirmation == .signOut else { return }
        isSigningOut = true
        let failureMessage = await onSignOut()
        isSigningOut = false
        if let failureMessage {
            viewModel.errorMessage = failureMessage
        } else {
            onClose()
        }
    }

    private func handleApplicationReset() async {
        onClose()
        await onApplicationReset()
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImageName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            Text(category.title)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
