import SwiftUI

enum ForumKeyboardSelection {
    static func moved(in ids: [String], from current: String?, delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta < 0 ? ids.last : ids.first
        }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}

/// Focus belongs to the result collection, never to the search field or reader.
struct ForumKeyboardBrowser<Content: View>: View {
    let threadIDs: [String]
    let onOpen: (String) -> Void
    @ViewBuilder let content: () -> Content
    @State private var keyboardSelection: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .environment(\.keyboardFocusedForumThreadID, isFocused ? keyboardSelection : nil)
                .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: [.down, .repeat]) { press in
                    guard isFocused, press.modifiers.isEmpty else { return .ignored }
                    if press.key == .return {
                        guard press.phase == .down else { return .handled }
                        guard let keyboardSelection, threadIDs.contains(keyboardSelection) else { return .ignored }
                        onOpen(keyboardSelection)
                    } else {
                        keyboardSelection = ForumKeyboardSelection.moved(
                            in: threadIDs, from: keyboardSelection, delta: press.key == .upArrow ? -1 : 1
                        )
                        if let keyboardSelection { proxy.scrollTo(keyboardSelection, anchor: .center) }
                    }
                    return .handled
                }
                .onChange(of: threadIDs) { _, ids in
                    if let keyboardSelection, !ids.contains(keyboardSelection) { self.keyboardSelection = nil }
                }
        }
    }
}

extension EnvironmentValues {
    @Entry var keyboardFocusedForumThreadID: String? = nil
}
