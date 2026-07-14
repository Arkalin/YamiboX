import SwiftUI
import YamiboXCore

/// The `NavigationStack` + `navigationDestination` wiring shared by the forum
/// tab and every reader-overlay forum stack, so all of them resolve the same
/// destinations identically.
struct ForumDestinationStackView<Root: View>: View {
    private let navigator: ForumDestinationNavigator
    private let root: Root

    init(navigator: ForumDestinationNavigator, @ViewBuilder root: () -> Root) {
        self.navigator = navigator
        self.root = root()
    }

    var body: some View {
        @Bindable var navigator = navigator
        return NavigationStack(path: $navigator.path) {
            root
                .navigationDestination(for: ForumDestination.self) { destination in
                    ForumDestinationScreen(destination: destination, navigator: navigator)
                }
        }
        .alert(L10n.string("forum.open_native_failed"), isPresented: actionErrorBinding, actions: {
            Button(L10n.string("common.ok")) {
                navigator.actionErrorMessage = nil
            }
        }, message: {
            Text(navigator.actionErrorMessage ?? "")
        })
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { navigator.actionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    navigator.actionErrorMessage = nil
                }
            }
        )
    }
}
