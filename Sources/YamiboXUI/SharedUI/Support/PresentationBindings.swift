import SwiftUI

extension Binding where Value == Bool {
    @MainActor
    static func presentation(
        isPresented: @escaping @MainActor () -> Bool,
        clearOnDismiss: @escaping @MainActor () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { isPresented() },
            set: { newValue in
                if !newValue {
                    Task { @MainActor in
                        clearOnDismiss()
                    }
                }
            }
        )
    }
}
