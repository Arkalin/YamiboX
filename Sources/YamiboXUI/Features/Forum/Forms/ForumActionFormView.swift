import SwiftUI
import YamiboXCore

struct ForumActionFormView: View {
    let model: ForumPageSession
    let document: ForumPageDocument
    let editorRegistry: ForumEditorRegistry
    let onURLTap: (URL) -> Void

    var body: some View {
        ForumFormPageView(model: model, document: document, composerForm: nil, editorRegistry: editorRegistry, onURLTap: onURLTap)
            .accessibilityIdentifier("forum-action-form")
    }
}
