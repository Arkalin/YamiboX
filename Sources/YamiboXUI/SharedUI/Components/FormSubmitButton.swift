import SwiftUI

/// Full-width submit button for a `Form` section: the label swaps to a
/// spinner while the submission runs. Disabling is left to the caller since
/// the predicate usually mixes validation with the in-flight flag.
struct FormSubmitButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                        .font(.headline)
                }
                Spacer()
            }
        }
    }
}
