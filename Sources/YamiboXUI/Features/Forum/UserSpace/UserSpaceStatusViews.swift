import SwiftUI
import YamiboXCore

struct UserSpaceLoadingView: View {
    var body: some View {
        ForumContentLoadingView()
    }
}

struct UserSpaceErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        LoadFailureView(message: message, retry: retry)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }
}

struct UserSpaceEmptyView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(message, systemImage: "tray")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }
}
