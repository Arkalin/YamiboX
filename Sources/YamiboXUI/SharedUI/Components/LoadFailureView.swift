import SwiftUI
import YamiboXCore

struct LoadFailureView: View {
    var title: String = L10n.string("common.load_failed")
    var systemImage: String = "exclamationmark.triangle"
    let message: String
    var details: LoadFailureDetails?
    var prominentRetry = false
    var showsRetry = true
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            VStack(spacing: 0) {
                if showsRetry {
                    let button = Button(L10n.string("common.retry"), action: retry).readerRemoteActivate(retry)
                    if prominentRetry { button.appProminentButtonStyle() } else { button }
                }
                LoadFailureDetailsButton(details: details, message: message)
            }
        }
    }
}
