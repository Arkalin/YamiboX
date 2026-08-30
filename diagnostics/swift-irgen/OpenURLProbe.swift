import SwiftUI

struct OpenURLProbe: View {
    @Environment(\.openURL) private var openURL
    @State private var errorMessage: String?

    var body: some View {
        Button("Probe") {
            openURL(URL(string: "shortcuts://create-automation")!) { accepted in
                guard !accepted else { return }
                errorMessage = "Failed"
            }
        }
    }
}
