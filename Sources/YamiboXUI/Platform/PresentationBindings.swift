import SwiftUI

extension Binding where Value == Bool {
    /// Presentation flag backed by optional model state (typically a
    /// `@Published` property): `true` while the state is present, and
    /// dismissal clears it on the next main-actor turn. SwiftUI writes this
    /// binding inside the presentation's dismiss update, and clearing a
    /// `@Published` property synchronously there publishes mid view update
    /// ("Publishing changes from within view updates is not allowed").
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
