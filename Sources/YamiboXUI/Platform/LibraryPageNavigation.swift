import SwiftUI
import UIKit
import YamiboXCore

/// Standalone iPad pages own a stack; embedded pages use their caller's stack.
struct LibraryPageNavigation<Content: View>: View {
    var ownsNavigation = true
    var isCloseEnabled = true
    var onClose: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        if ownsNavigation, UIDevice.current.userInterfaceIdiom == .pad {
            NavigationStack {
                content()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if let onClose {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.string("common.close"), systemImage: "xmark", action: onClose)
                                    .labelStyle(.iconOnly)
                                    .disabled(!isCloseEnabled)
                            }
                        }
                    }
            }
        } else {
            content()
        }
    }
}
