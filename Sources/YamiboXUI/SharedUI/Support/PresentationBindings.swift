import SwiftUI

extension Binding where Value == Bool {
    @MainActor
    static func presentation<Identity: Equatable & Sendable>(
        isPresented: @escaping @MainActor () -> Bool,
        identity: @escaping @MainActor () -> Identity,
        clearOnDismiss: @escaping @MainActor () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { isPresented() },
            set: { newValue in
                guard !newValue, isPresented() else { return }
                let dismissedIdentity = identity()
                Task { @MainActor in
                    guard isPresented(), identity() == dismissedIdentity else { return }
                    clearOnDismiss()
                }
            }
        )
    }
}
