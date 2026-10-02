import SwiftUI
import UIKit

/// The system picker edits a local draft. The containing sheet supplies swipe
/// dismissal and commits once, without adding another close button.
struct ThemeColorPicker: UIViewControllerRepresentable {
    @Binding var colorHex: UInt32

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = UIColor(hex: colorHex)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
        if Self.sRGBHex(picker.selectedColor) != colorHex {
            picker.selectedColor = UIColor(hex: colorHex)
        }
    }

    private static func sRGBHex(_ color: UIColor) -> UInt32? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else { return nil }
        func channel(_ index: Int) -> UInt32 {
            UInt32((min(max(components[index], 0), 1) * 255).rounded())
        }
        return (channel(0) << 16) | (channel(1) << 8) | channel(2)
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: ThemeColorPicker

        init(_ parent: ThemeColorPicker) { self.parent = parent }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            guard let hex = ThemeColorPicker.sRGBHex(color) else { return }
            parent.colorHex = hex
        }
    }
}
