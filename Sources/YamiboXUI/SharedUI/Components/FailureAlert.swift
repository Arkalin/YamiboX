import SwiftUI
import YamiboXCore

private struct FailureAlertModifier<Actions: View>: ViewModifier {
    @Environment(\.readerDeviceInteraction) private var deviceInteraction
    let title: String
    let message: String?
    let details: LoadFailureDetails?
    let offersDetails: Bool
    @Binding var isPresented: Bool
    let actions: Actions
    @State private var presentedDetails: PresentedLoadFailure?

    func body(content: Content) -> some View {
        let snapshot = details ?? LoadFailureDetails(message: message ?? title)
        if let deviceInteraction {
            content.onChange(of: isPresented, initial: true) { _, isPresented in
                guard isPresented else { return }
                self.isPresented = false
                if offersDetails, !snapshot.isSilentForumFailure {
                    deviceInteraction.showDetails(snapshot)
                } else {
                    deviceInteraction.present { id in
                        VStack(spacing: 12) {
                            Text(title).font(.headline)
                            Text(message ?? snapshot.summary).foregroundStyle(.secondary)
                            Button(L10n.string("common.ok")) { deviceInteraction.finish(id) }
                                .buttonStyle(.bordered)
                        }
                        .padding(24)
                        .presentationDetents([.medium])
                    }
                }
            }
        } else {
            localPresentation(content, snapshot: snapshot)
        }
    }

    private func localPresentation(_ content: Content, snapshot: LoadFailureDetails) -> some View {
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
