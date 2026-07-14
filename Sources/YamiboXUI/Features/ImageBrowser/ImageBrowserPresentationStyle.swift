import SwiftUI

/// How the full-screen image browser is presented and dismissed.
///
/// `.zoom` uses the system zoom transition: the browser grows out of the
/// tapped thumbnail and shrinks back into it on dismiss. It requires the
/// presenting hierarchy to mark thumbnails with
/// `imageBrowserZoomSource(id:in:)` using ids that match the browser items'
/// ids — the browser retargets `sourceID` to the currently viewed page, so
/// dismissing after paging lands on that page's thumbnail (the system falls
/// back to a plain transition when the source is off screen).
///
/// `.fade` cross-dissolves instead, for hosts that have no SwiftUI thumbnail
/// to anchor to (e.g. images embedded in the novel reader's text layout).
enum ImageBrowserPresentationStyle {
    case fade
    case zoom(Namespace.ID)
}

private struct ImageBrowserZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Namespace connecting image thumbnails to the browser's zoom
    /// transition. Set by hosts that present the browser with `.zoom`; nil
    /// leaves thumbnails unmarked so they keep working under `.fade` hosts.
    var imageBrowserZoomNamespace: Namespace.ID? {
        get { self[ImageBrowserZoomNamespaceKey.self] }
        set { self[ImageBrowserZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as the zoom-transition source for the browser item
    /// with `id`. No-op when `namespace` is nil.
    @ViewBuilder
    func imageBrowserZoomSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
