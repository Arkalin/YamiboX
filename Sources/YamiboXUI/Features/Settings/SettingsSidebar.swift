import SwiftUI
import YamiboXCore

enum SettingsSidebarDestination: Hashable {
    case category(SettingsCategory)
    case about
    case accounts
}

struct SettingsSidebar: View {
    let viewModel: SystemSettingsViewModel
    @Binding var selection: SettingsSidebarDestination?
    let accountManagementAvailable: Bool
    let isSigningOut: Bool
    let aboutTitle: String
    /// Use the window's size class, not this potentially compact column's.
    let showsCloseButton: Bool
    let onSignOut: () -> Void
    let onClose: () -> Void
    var usesSelectionButtons = false
    var usesCompactLayout = false
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        List(selection: usesSelectionButtons ? .constant(nil) : $selection) {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    ForEach(SettingsCategory.allCases) { category in
                        destinationRow(.category(category)) {
                            Label(category.title, systemImage: category.systemImageName)
                        }
                    }
                }
                .listRowSeparator(usesCompactLayout ? .automatic : .hidden)
                .listSectionSeparator(usesCompactLayout ? .automatic : .hidden)
                Section {
                    destinationRow(.about) {
                        Label(aboutTitle, systemImage: "info.circle")
                    }
                }
                .listRowSeparator(usesCompactLayout ? .automatic : .hidden)
                .listSectionSeparator(usesCompactLayout ? .automatic : .hidden)
                if accountManagementAvailable || viewModel.isLoggedIn {
                    Section {
                        if accountManagementAvailable {
                            destinationRow(.accounts) {
                                Label(L10n.string("account.switch"), systemImage: "arrow.left.arrow.right")
                            }
                        }
                        if viewModel.isLoggedIn {
                            Button(role: .destructive, action: onSignOut) {
                                Label(L10n.string("mine.sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .listRowBackground(usesCompactLayout ? Color(uiColor: .secondarySystemGroupedBackground) : .clear)
                            .accessibilityIdentifier("settings.sidebar.signOut")
                        }
                    }
                    .listRowSeparator(usesCompactLayout ? .automatic : .hidden)
                    .listSectionSeparator(usesCompactLayout ? .automatic : .hidden)
                }
            } else {
                SettingsSidebarSearchResults(
                    query: searchText,
                    selection: $selection,
                    usesSelectionButtons: usesSelectionButtons,
                    usesCompactLayout: usesCompactLayout
                )
            }
        }
        .disabled(viewModel.isBusy || isSigningOut)
        .sidebarListSurface(isCompact: usesCompactLayout)
        .navigationTitle(L10n.string("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: usesSelectionButtons ? .navigationBarDrawer(displayMode: .always) : .automatic,
            prompt: L10n.string("settings.search.placeholder")
        )
        .searchFocused($isSearchFocused)
        .background {
            // Keep Cmd-F without duplicating the visible search field.
            Button(L10n.string("common.search")) {
                isSearchPresented = true
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(viewModel.isBusy || isSigningOut)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("common.close"), systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .accessibilityIdentifier("settings.sidebar")
    }

    private func destinationRow<Content: View>(
        _ destination: SettingsSidebarDestination,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSidebarDestinationRow(
            destination: destination,
            selection: $selection,
            usesSelectionButtons: usesSelectionButtons,
            usesCompactLayout: usesCompactLayout,
            content: content
        )
    }
}

private struct SettingsSidebarSearchResults: View {
    let query: String
    @Binding var selection: SettingsSidebarDestination?
    let usesSelectionButtons: Bool
    let usesCompactLayout: Bool

    var body: some View {
        Section {
            let results = SettingsSearchRegistry.search(query)
            if results.isEmpty {
                Text(L10n.string("settings.search.no_results"))
                    .foregroundStyle(.secondary)
                    .listRowBackground(usesCompactLayout ? Color(uiColor: .secondarySystemGroupedBackground) : .clear)
            } else {
                ForEach(results) { entry in
                    SettingsSidebarDestinationRow(
                        destination: .category(entry.category),
                        selection: $selection,
                        usesSelectionButtons: usesSelectionButtons,
                        usesCompactLayout: usesCompactLayout
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.category.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listRowSeparator(usesCompactLayout ? .automatic : .hidden)
        .listSectionSeparator(usesCompactLayout ? .automatic : .hidden)
    }
}

private struct SettingsSidebarDestinationRow<Content: View>: View {
    let destination: SettingsSidebarDestination
    @Binding var selection: SettingsSidebarDestination?
    let usesSelectionButtons: Bool
    let usesCompactLayout: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if usesSelectionButtons {
            Button {
                selection = destination
            } label: {
                content()
            }
            .tag(destination)
            .sidebarCategorySelection(isSelected: usesCompactLayout ? nil : selection == destination)
            .accessibilityAddTraits(selection == destination ? .isSelected : [])
        } else {
            NavigationLink(value: destination, label: content)
        }
    }
}

struct SettingsSidebarDetail: View {
    let destination: SettingsSidebarDestination?
    let dependencies: SettingsDependencies
    let viewModel: SystemSettingsViewModel
    let peripheralInput: ReaderPeripheralInputManager?
    let accountSwitcher: AccountSwitchCoordinator?
    let onReset: () async -> Void
    var usesCompactLayout = false

    var body: some View {
        detailContent
            .scrollContentBackground(usesCompactLayout ? .automatic : .hidden)
            .background(Color(uiColor: usesCompactLayout ? .systemGroupedBackground : .systemBackground).ignoresSafeArea())
            .toolbarBackground(Color(uiColor: usesCompactLayout ? .systemGroupedBackground : .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case let .category(category):
            SettingsCategoryPage(
                category: category,
                dependencies: dependencies,
                viewModel: viewModel,
                peripheralInput: peripheralInput,
                onReset: onReset
            )
        case .about:
            AboutView()
        case .accounts:
            if let accountSwitcher { AccountManagementView(switcher: accountSwitcher) }
        case nil:
            ContentUnavailableView(L10n.string("settings.title"), systemImage: "gearshape")
        }
    }
}

struct SettingsCategoryPage: View {
    let category: SettingsCategory
    let dependencies: SettingsDependencies
    let viewModel: SystemSettingsViewModel
    let peripheralInput: ReaderPeripheralInputManager?
    let onReset: () async -> Void

    var body: some View {
        switch category {
        case .general:
            SettingsGeneralView(viewModel: viewModel.general)
        case .home:
            SettingsHomePageView(viewModel: viewModel.home)
        case .forum:
            SettingsForumView(viewModel: viewModel.forum)
        case .favorites:
            SettingsFavoritesView(dependencies: dependencies, viewModel: viewModel.favorites)
        case .reading:
            SettingsReadingView(
                viewModel: viewModel.reading,
                peripheralsViewModel: viewModel.peripherals,
                peripheralInput: peripheralInput
            )
        case .storage:
            SettingsStorageView(
                dependencies: dependencies,
                viewModel: viewModel.storage,
                offlineCacheManagement: viewModel.offlineCacheManagement,
                mangaDirectoryManagement: viewModel.mangaDirectoryManagement,
                onReset: onReset
            )
        }
    }
}
