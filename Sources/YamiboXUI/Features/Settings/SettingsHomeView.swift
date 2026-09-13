import SwiftUI
import UIKit
import YamiboXCore

/// iPhone settings are pushed into Mine. iPad owns an independent split
/// container so both settings columns survive window-size changes.
public struct SettingsHomeView: View {
    private let onClose: () -> Void
    @State private var state: SettingsPresentationState
    @State private var searchText = ""
    @State private var pushedCategory: SettingsCategory?
    @State private var isAboutPushed = false
    @State private var isAccountManagementPushed = false
    @State private var selectedDestination: SettingsSidebarDestination? = .category(.general)
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.appTheme) private var appTheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        dependencies: SettingsDependencies,
        peripheralInput: ReaderPeripheralInputManager? = nil,
        onSignOut: @escaping @MainActor () async -> LoadFailureDetails?,
        onApplicationReset: @escaping @MainActor () async -> Void,
        onClose: @escaping () -> Void,
        accountSwitcher: AccountSwitchCoordinator? = nil
    ) {
        _state = State(initialValue: SettingsPresentationState(
            dependencies: dependencies,
            peripheralInput: peripheralInput,
            onSignOut: onSignOut,
            onApplicationReset: onApplicationReset,
            onClose: onClose,
            accountSwitcher: accountSwitcher
        ))
        self.onClose = onClose
    }

    public var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    SettingsSidebar(
                        viewModel: state.viewModel,
                        selection: sidebarSelection,
                        accountManagementAvailable: state.accountSwitcher != nil,
                        isSigningOut: state.isSigningOut,
                        aboutTitle: state.aboutTitle,
                        showsCloseButton: horizontalSizeClass == .compact,
                        onSignOut: { state.pendingConfirmation = .signOut },
                        onClose: onClose,
                        usesCompactLayout: horizontalSizeClass == .compact
                    )
                    .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
                } detail: {
                    NavigationStack {
                        SettingsSidebarDetail(
                            destination: selectedDestination,
                            dependencies: state.dependencies,
                            viewModel: state.viewModel,
                            peripheralInput: state.peripheralInput,
                            accountSwitcher: state.accountSwitcher,
                            onReset: state.handleApplicationReset,
                            usesCompactLayout: horizontalSizeClass == .compact
                        )
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.string("common.close"), systemImage: "xmark", action: onClose)
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                    .id(selectedDestination)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                phoneSettingsList
            }
        }
        .modifier(SettingsPresentationEffects(state: state))
    }

    private var phoneSettingsList: some View {
        List {
            if isSearching {
                searchResultsSection
            } else {
                categorySection
                aboutSection
                if state.viewModel.isLoggedIn || state.accountSwitcher != nil {
                    signOutSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("settings.title"))
        .yamiboInlineNavigationTitleDisplayMode()
        .searchable(text: $searchText, prompt: L10n.string("settings.search.placeholder"))
        .navigationDestination(isPresented: $isAccountManagementPushed) {
            if let accountSwitcher = state.accountSwitcher { AccountManagementView(switcher: accountSwitcher) }
        }
        .navigationDestination(isPresented: $isAboutPushed) {
            AboutView()
        }
        .navigationDestination(item: $pushedCategory) { category in
            SettingsCategoryPage(
                category: category,
                dependencies: state.dependencies,
                viewModel: state.viewModel,
                peripheralInput: state.peripheralInput,
                onReset: state.handleApplicationReset
            )
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarSelection: Binding<SettingsSidebarDestination?> {
        Binding {
            selectedDestination
        } set: { destination in
            guard state.canNavigate else { return }
            selectedDestination = destination
            if destination != nil { compactColumn = .detail }
        }
    }

    private var categorySection: some View {
        Section {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    pushedCategory = category
                } label: {
                    SettingsCategoryRow(category: category)
                }
                .disabled(state.viewModel.isBusy)
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Button {
                isAboutPushed = true
            } label: {
                SystemSettingsRow(title: state.aboutTitle, titleColor: appTheme.controlAccent)
            }
            .disabled(state.viewModel.isBusy)
        }
    }

    private var signOutSection: some View {
        Section {
            if state.accountSwitcher != nil {
                Button {
                    isAccountManagementPushed = true
                } label: {
                    Label(L10n.string("account.switch"), systemImage: "arrow.left.arrow.right")
                }
                .disabled(!state.canNavigate)
            }
            if state.viewModel.isLoggedIn {
                Button(role: .destructive) {
                    state.pendingConfirmation = .signOut
                } label: {
                    Label {
                        Text(L10n.string("mine.sign_out"))
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(!state.canNavigate)
            }
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
                    .disabled(state.viewModel.isBusy)
                }
            }
        }
    }

}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImageName)
                .foregroundStyle(appTheme.controlAccent)
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
