import SwiftUI
import YamiboXCore

private struct FailureAlertModifier<Actions: View>: ViewModifier {
    let title: String
    let message: String?
    let details: LoadFailureDetails?
    let offersDetails: Bool
    @Binding var isPresented: Bool
    let actions: Actions
    @State private var presentedDetails: PresentedLoadFailure?

    func body(content: Content) -> some View {
        let snapshot = details ?? LoadFailureDetails(message: message ?? title)
        content
            .alert(title, isPresented: Binding(
                get: { isPresented && !snapshot.isSilentForumFailure },
                set: { isPresented = $0 }
            )) {
                actions
                if offersDetails {
                    Button(L10n.string("load_failure.details")) {
                        // Freeze before the alert binding clears the model's error.
                        isPresented = false
                        presentedDetails = PresentedLoadFailure(details: snapshot)
                    }
                    .accessibilityIdentifier("alert-failure-details")
                }
            } message: {
                Text(message ?? "")
            }
            .overlay(alignment: .bottom) {
                if isPresented, snapshot.isSilentForumFailure {
                    HStack {
                        Text(message ?? snapshot.summary)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L10n.string("common.close")) { isPresented = false }
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
            .sheet(item: $presentedDetails) { failure in
                LoadFailureDetailsSheet(details: failure.details)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: message) {
                if message != nil { presentedDetails = nil }
            }
            .onDisappear { presentedDetails = nil }
    }
}

extension View {
    func failureAlert<Actions: View>(
        _ title: String,
        message: String?,
        details: LoadFailureDetails? = nil,
        offersDetails: Bool = true,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        modifier(FailureAlertModifier(
            title: title, message: message, details: details, offersDetails: offersDetails,
            isPresented: isPresented, actions: actions()
        ))
    }
}
