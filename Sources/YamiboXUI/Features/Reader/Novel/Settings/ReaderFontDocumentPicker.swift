import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Import a system-provided copy instead of opening a provider-owned file in
/// place. Core then copies it to its content-addressed, durable font directory.
struct ReaderFontDocumentPicker: UIViewControllerRepresentable {
    struct Request: Identifiable {
        let id = UUID()
    }

    let onFinish: ([URL]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = ["ttf", "otf", "ttc", "otc"].compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ picker: UIDocumentPickerViewController, coordinator: Coordinator) {
        picker.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: ([URL]?) -> Void
        private var didFinish = false

        init(onFinish: @escaping ([URL]?) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(nil)
        }

        private func finish(_ urls: [URL]?) {
            guard !didFinish else { return }
            didFinish = true
            onFinish(urls)
        }
    }
}
