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
            .navigationTitle(L10n.string(isEditing ? "forum.blog.edit" : "user_space.write_blog"))
    }

    private var isEditing: Bool {
        let items = URLComponents(url: document.url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        return items.contains { $0.name == "blogid" && (Int($0.value ?? "") ?? 0) > 0 }
    }
}

/// Blog settings follow the server's available controls and choices, while the
/// layout and conditional privacy controls belong to the native composer.
struct ForumBlogEditorFields: View {
    let form: ForumForm
    @Binding var values: [String: [String]]
    @Binding var htmlSourceFields: Set<String>
    let editorRegistry: ForumEditorRegistry?
    let disabled: Bool

    static let fieldNames: Set<String> = [
        "subject", "message", "classid", "catid", "tag", "tags", "friend",
        "password", "target_names", "noreply", "makefeed"
    ]

    var body: some View {
        Section {
            fields(named: ["subject", "message"])
        }
        if form.fields.contains(where: { ["classid", "catid", "tag", "tags"].contains($0.name) }) {
            Section(L10n.string("forum.blog.organization")) {
                fields(named: ["catid", "classid", "tag", "tags"])
            }
        }
        if form.fields.contains(where: { $0.name == "friend" }) {
            Section {
                fields(named: ["friend"])
                if privacy == "4" { fields(named: ["password"]) }
                if privacy == "2" { fields(named: ["target_names"]) }
            } header: {
                Text(L10n.string("forum.blog.visibility"))
            } footer: {
                if privacy == "2" { Text(L10n.string("forum.blog.friends_hint")) }
            }
        }
        if form.fields.contains(where: { ["noreply", "makefeed"].contains($0.name) }) {
            Section(L10n.string("forum.blog.settings")) {
                fields(named: ["noreply", "makefeed"])
            }
        }
    }

    private var privacy: String? {
        guard let field = form.fields.first(where: { $0.name == "friend" }) else { return nil }
        return (values[field.id] ?? field.initialValues).first
    }

    private func fields(named names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            ForEach(form.fields.filter { $0.name == name }) { field in
                ForumFieldView(
                    field: field,
                    values: Binding(get: { values[field.id] ?? field.initialValues }, set: { values[field.id] = $0 }),
                    isComposer: true,
                    isBlog: true,
                    isHTMLSource: Binding(get: { htmlSourceFields.contains(field.id) }, set: {
                        if $0 { htmlSourceFields.insert(field.id) } else { htmlSourceFields.remove(field.id) }
                    }),
                    editorController: field.name == "message" ? editorRegistry?.controller(for: field.id) : nil
                )
                .disabled(disabled || field.isReadOnly)
            }
        }
    }
}
