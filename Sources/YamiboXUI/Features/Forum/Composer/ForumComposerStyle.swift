import SwiftUI
import YamiboXCore

// Shared presentation for ratings, comments, and replies. Entry points only
// supply their state and actions; editor styling belongs in this module.
enum ForumComposerStyle {
    static let contentInset: CGFloat = 16
    static let controlSize: CGFloat = 44
    static let fieldSpacing: CGFloat = 20
}

struct ForumComposerSurface: ViewModifier {
    @Environment(\.appTheme) private var theme
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(Color(.systemBackground))
                .tint(theme.controlAccent)
                .yamiboInlineNavigationTitleDisplayMode()
        } else {
            content
        }
    }
}

struct ForumComposerSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(ForumComposerSurface())
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
    }
}

struct ForumComposerSubmitButton: View {
    var title = L10n.string("forum.thread.publish")
    var identifier = "forum-composer-send"
    let isSubmitting: Bool
    let canSubmit: Bool
    let submit: () -> Void

    var body: some View {
        Button(action: submit) {
            ZStack {
                Image(systemName: "paperplane.fill").opacity(isSubmitting ? 0 : 1)
                if isSubmitting { ProgressView() }
            }
            .frame(minWidth: ForumComposerStyle.controlSize, minHeight: ForumComposerStyle.controlSize)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .disabled(!canSubmit)
    }
}

struct ForumComposerToolbar: ToolbarContent {
    var identifier = "forum-composer"
    let isBusy: Bool
    let isSubmitting: Bool
    let canSubmit: Bool
    let close: () -> Void
    let submit: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(minWidth: ForumComposerStyle.controlSize, minHeight: ForumComposerStyle.controlSize)
            }
            .accessibilityLabel(L10n.string("common.cancel"))
            .accessibilityIdentifier("\(identifier)-close")
            .disabled(isBusy)
        }
        ToolbarItem(placement: .confirmationAction) {
            ForumComposerSubmitButton(identifier: "\(identifier)-send", isSubmitting: isSubmitting,
                                      canSubmit: canSubmit, submit: submit)
        }
    }
}
