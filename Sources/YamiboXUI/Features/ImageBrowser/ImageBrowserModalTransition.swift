#if os(iOS)
import SwiftUI
import UIKit

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
