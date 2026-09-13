import SwiftUI
import UIKit
import YamiboXCore

struct LocalFavoriteBrowseSearch: ViewModifier {
    @Bindable var organizer: FavoriteLibraryOrganizer
    let isActive: Bool
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $organizer.filter.searchText,
                isPresented: $isSearchPresented,
                prompt: L10n.string("favorites.search.placeholder")
            )
            .searchFocused($isSearchFocused)
            .background {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // Keep Cmd-F without duplicating the visible search field.
                    Button(L10n.string("common.search")) {
                        guard isActive else { return }
                        isSearchPresented = true
                        isSearchFocused = true
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!isActive)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            // Key presses bubble up only from focused content descendants.
            // Search fields and presented editors retain their native Cmd-A.
            .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
                guard isActive, !isSearchFocused, press.modifiers == .command else { return .ignored }
                organizer.selectAllVisible()
                return .handled
            }
            .onKeyPress(.escape) {
                guard isActive, !isSearchFocused, organizer.selection.isSelectionMode else { return .ignored }
                organizer.selection.exitSelectionMode()
                return .handled
            }
    }
}

struct LocalFavoriteKeyboardActivation: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable(UIDevice.current.userInterfaceIdiom == .pad, interactions: .activate)
            .onKeyPress(.return) {
                action()
                return .handled
            }
    }
}
