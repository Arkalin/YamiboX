#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI's `fullScreenCover` always presents/dismisses with a vertical slide and exposes no
/// way to change that, so this reaches into the presented `UIViewController` to switch it to a
/// cross-dissolve (fade) transition instead — used so the image browser fades in/out rather than
/// sliding, matching the rest of its dismiss animation. Only the browser's `.fade` presentation
/// uses this; `.zoom` hosts get the system zoom transition via `navigationTransition` instead.
private struct ModalTransitionStyleConfigurator: UIViewControllerRepresentable {
    let style: UIModalTransitionStyle

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            var presentedController: UIViewController? = uiViewController
            while let parent = presentedController?.parent {
                presentedController = parent
            }
            presentedController?.modalTransitionStyle = style
        }
    }
}

extension View {
    func modalTransitionStyle(_ style: UIModalTransitionStyle) -> some View {
        background(ModalTransitionStyleConfigurator(style: style))
    }
}
#endif
