import SwiftUI
import YamiboXCore

struct ForumBlogEditorView: View {
    let model: ForumPageSession
    let document: ForumPageDocument
    let editorRegistry: ForumEditorRegistry
    let onSubmissionSucceeded: ((TransientFeedback) -> Void)?
    let onURLTap: (URL) -> Void

    var body: some View {
        ForumFormPageView(model: model, document: document, composerForm: document.forms.first { $0.kind == .blog },
                          editorRegistry: editorRegistry, onSubmissionSucceeded: onSubmissionSucceeded, onURLTap: onURLTap)
            .accessibilityIdentifier("forum-blog-editor")
    }
}
