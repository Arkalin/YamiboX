import SwiftUI
import YamiboXCore

struct ForumPostEditorView: View {
    let model: ForumPageSession
    let document: ForumPageDocument
    let editorRegistry: ForumEditorRegistry
    let onSubmissionSucceeded: ((TransientFeedback) -> Void)?
    let onURLTap: (URL) -> Void

    private var form: ForumForm? { document.forms.first { $0.kind == .thread } }
    var mode: ForumPostEditorMode? {
        form.flatMap { ForumPostEditorMode(url: $0.actionURL) } ?? ForumPostEditorMode(url: document.url)
    }

    var body: some View {
        Group {
            if mode == .reply, let form {
                ForumPostReplyFields(session: model, form: form, editorRegistry: editorRegistry,
                                     onSubmissionSucceeded: onSubmissionSucceeded, onURLTap: onURLTap)
            } else {
                ForumFormPageView(model: model, document: document, composerForm: form, editorRegistry: editorRegistry,
                                  onSubmissionSucceeded: onSubmissionSucceeded, onURLTap: onURLTap)
            }
        }
        .accessibilityIdentifier("forum-post-editor-\(mode?.rawValue ?? "form")")
    }
}
