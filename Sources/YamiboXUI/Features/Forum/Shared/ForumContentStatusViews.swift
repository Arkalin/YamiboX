import SwiftUI
import YamiboXCore

struct ForumContentLoadingView: View {
    /// How the placeholder occupies its container: embedded in scroll
    /// content, stretched over the available space, or stretched with the
    /// forum page background behind it.
    enum Layout {
        case inline
        case fills
        case fillsPage
    }

    var text: String = L10n.string("common.loading")
    var layout: Layout = .inline

    var body: some View {
        switch layout {
        case .inline:
            core
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
        case .fills:
            core
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fillsPage:
            core
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .forumPageBackground()
        }
    }

    private var core: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(ForumColors.secondaryText)
        }
    }
}

struct ForumContentErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ForumColors.orangeAccent)
            Text(message)
                .font(.body)
                .foregroundStyle(ForumColors.textDark)
                .multilineTextAlignment(.center)
            Button {
                retry()
            } label: {
                Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .forumCardBackground()
    }
}
