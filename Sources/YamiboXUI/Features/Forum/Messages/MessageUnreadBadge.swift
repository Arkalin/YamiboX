import YamiboXCore
import SwiftUI
import UIKit

enum MessageUnreadBadge {
    static func text(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    static func tabValue(for count: Int) -> String? {
        count > 0 ? "" : nil
    }

    static func accessibilityValue(for count: Int) -> String {
        count > 0 ? L10n.string("message_center.unread_accessibility", count) : ""
    }
}

extension View {
    func messageUnreadTabAccessibility(count: Int) -> some View {
        background {
            MessageUnreadTabAccessibility(value: MessageUnreadBadge.accessibilityValue(for: count))
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

// SwiftUI's tabItem label drops accessibilityValue when creating the native
// tab. Update the owning tab item without replacing the system tab bar.
private struct MessageUnreadTabAccessibility: UIViewControllerRepresentable {
    let value: String

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.value = value
        controller.applyValue()
    }

    final class Controller: UIViewController {
        var value = ""

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyValue()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyValue()
        }

        func applyValue() {
            var owner: UIViewController = self
            while let parent = owner.parent {
                if parent is UITabBarController {
                    owner.tabBarItem.accessibilityValue = value.isEmpty ? nil : value
                    return
                }
                owner = parent
            }
        }
    }
}
