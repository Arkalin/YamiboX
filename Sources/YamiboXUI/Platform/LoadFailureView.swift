import SwiftUI
import YamiboXCore

/// The standard "load failed + retry" state: an unavailable-content layout
/// with the failure summary as the title, the underlying error as the
/// description, and a retry button.
struct LoadFailureView: View {
    var title: String = L10n.string("common.load_failed")
    var systemImage: String = "exclamationmark.triangle"
    let message: String
    var prominentRetry = false
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if prominentRetry {
                Button(L10n.string("common.retry"), action: retry)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(L10n.string("common.retry"), action: retry)
            }
        }
    }
}
