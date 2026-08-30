import SwiftUI

#if !NONISOLATED_MODEL
@MainActor
#endif
#if !NO_OBSERVATION
@Observable
#endif
final class DiagnosticModel {
    var enabled = false

    func update(_ value: Bool) {
        enabled = value
    }
}

struct BindingSetterProbe: View {
    let model: DiagnosticModel

    var body: some View {
        Toggle("Probe", isOn: binding)
    }

    private var binding: Binding<Bool> {
        #if EXPLICIT_SETTER
        Binding(get: { model.enabled }, set: { model.update($0) })
        #else
        Binding(get: { model.enabled }, set: model.update)
        #endif
    }
}
