import SwiftUI

enum ImageBrowserPresentationStyle {
    case fade
    case zoom(Namespace.ID)
}

private struct ImageBrowserZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var imageBrowserZoomNamespace: Namespace.ID? {
        get { self[ImageBrowserZoomNamespaceKey.self] }
        set { self[ImageBrowserZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func imageBrowserZoomSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
