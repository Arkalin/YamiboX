import SwiftUI
import YamiboXCore

struct ForumFormSection: View {
    let form: ForumForm
    @Binding var values: [String: [String]]
    @Binding var htmlSourceFields: Set<String>
    @Binding var files: [ForumFormFile]
    let uploads: [ForumUploadConfiguration]
    let attachments: [ForumUploadedAttachment]
    let disabled: Bool
    let onChooseFile: (ForumFormField?, ForumUploadConfiguration?) -> Void
    let onSubmit: (ForumFormButton) -> Void
    let onURLTap: (URL) -> Void
    var editorRegistry: ForumEditorRegistry? = nil
    var composerContext = ForumComposerContext()
    var editorDisabled: Bool? = nil
    var onDrafts: (() -> Void)?
    var draftStatus: String?
    @State private var showsOptions = false

    private var isComposer: Bool { form.kind != .standard }
    private var primaryFields: [ForumFormField] {
        form.fields.filter { ["subject", "message", "typeid", "classid", "friend", "password", "target_names"].contains($0.name) || $0.name.hasPrefix("polloption") }
    }
    private var otherFields: [ForumFormField] {
        form.fields.filter { field in field.kind != .file && !primaryFields.contains { $0.id == field.id } }
    }

    var body: some View {
        Section {
            if !form.instructions.isEmpty {
                ForumThreadContentBlocksView(
                    blocks: form.instructions, fallbackText: "", refererURL: form.actionURL,
                    onImageTap: { _, url, _, _ in onURLTap(url) }, onURLTap: onURLTap
                )
            }
            ForEach(isComposer ? primaryFields : form.fields.filter { $0.kind != .file }) { field in
                fieldView(field)
            }
        }
        if !uploads.isEmpty || !attachments.isEmpty || form.fields.contains(where: { $0.kind == .file }) {
            Section(L10n.string("forum.native.attachments")) {
                if !uploads.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { uploadButtons }
                        VStack(alignment: .leading, spacing: 12) { uploadButtons }
                    }
                }
                ForEach(form.fields.filter { $0.kind == .file }) { field in fileField(field) }
                ForEach(attachments) { attachment in
                    Label(attachment.name, systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        if isComposer && !otherFields.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsOptions) {
                    ForEach(otherFields) { field in fieldView(field) }
                } label: {
                    Label(L10n.string("forum.native.more_options"), systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("native-composer-options")
            }
        }
        if !isComposer {
            Section { submitButtons }
        }
    }

    private var uploadButtons: some View {
        ForEach(uploads) { configuration in
            Button { onChooseFile(nil, configuration) } label: {
                Label(L10n.string(configuration.kind == .threadAttachment ? "forum.native.upload_attachment" : "forum.native.upload_image"),
                      systemImage: configuration.kind == .threadAttachment ? "paperclip" : "photo.badge.plus")
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(disabled)
        }
    }

    private var submitButtons: some View {
        ForEach(form.buttons) { button in
            Button(role: form.isDestructive ? .destructive : nil) { onSubmit(button) } label: {
                Label(button.title, systemImage: form.isDestructive ? "trash" : "paperplane")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .disabled(disabled)
            .accessibilityIdentifier("native-form-submit-\(button.id)")
        }
    }

    private func fieldView(_ field: ForumFormField) -> some View {
        ForumFieldView(
            field: field,
            values: Binding(get: { values[field.id] ?? field.initialValues }, set: { values[field.id] = $0 }),
            isComposer: isComposer,
            isBlog: form.kind == .blog,
            isHTMLSource: Binding(get: { htmlSourceFields.contains(field.id) }, set: {
                if $0 { htmlSourceFields.insert(field.id) } else { htmlSourceFields.remove(field.id) }
            }),
            editorController: isComposer && field.name == "message" ? editorRegistry?.controller(for: field.id) : nil,
            composerContext: composerContext,
            parsesBBCode: !isChecked("bbcodeoff"), parsesEmoticons: !isChecked("smileyoff"),
            onDrafts: onDrafts, draftStatus: draftStatus
        )
        .disabled((form.kind == .thread ? editorDisabled ?? disabled : disabled) || field.isReadOnly)
    }

    private func isChecked(_ name: String) -> Bool {
        form.fields.first(where: { $0.name == name }).map { !(values[$0.id] ?? $0.initialValues).isEmpty } ?? false
    }

    private func fileField(_ field: ForumFormField) -> some View {
        LabeledContent(field.label) {
            Button { onChooseFile(field, nil) } label: {
                Label(files.first { $0.fieldName == field.name }?.file.name ?? L10n.string("forum.native.choose_file"), systemImage: "paperclip")
                    .lineLimit(2)
            }
            .disabled(disabled)
            if files.contains(where: { $0.fieldName == field.name }) {
                Button { files.removeAll { $0.fieldName == field.name } } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel(L10n.string("common.remove"))
                    .disabled(disabled)
            }
        }
    }
}

private struct ForumFieldView: View {
    let field: ForumFormField
    @Binding var values: [String]
    let isComposer: Bool
    let isBlog: Bool
    @Binding var isHTMLSource: Bool
    var editorController: ForumEditorController? = nil
    var composerContext = ForumComposerContext()
    var parsesBBCode = true
    var parsesEmoticons = true
    var onDrafts: (() -> Void)?
    var draftStatus: String?

    private var text: Binding<String> {
        Binding(get: { values.first ?? "" }, set: { values = [$0] })
    }

    var body: some View {
        Group {
            switch field.kind {
            case .text, .email, .number:
                if isComposer && field.name == "subject" {
                    TextField(field.label, text: text, axis: .vertical)
                        .font(.title3.weight(.semibold))
                        .padding(.vertical, 6)
                        .accessibilityLabel(field.label)
                } else {
                    LabeledContent(field.label) {
                        TextField(field.label, text: text, axis: .vertical)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(field.kind == .email ? .emailAddress : (field.kind == .number ? .numbersAndPunctuation : .default))
                    }
                }
            case .password:
                LabeledContent(field.label) { SecureField(field.label, text: text) }
            case .multiline:
                VStack(alignment: .leading, spacing: 8) {
                    Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                    if isComposer && field.name == "message" {
                        ForumComposerEditor(text: text, isBlog: isBlog, isHTMLSource: $isHTMLSource, editorController: editorController,
                                            composerContext: composerContext, parsesBBCode: parsesBBCode, parsesEmoticons: parsesEmoticons,
                                            onDrafts: onDrafts, draftStatus: draftStatus)
                    } else {
                        TextEditor(text: text).frame(minHeight: 110)
                    }
                }
            case .choice:
                Picker(field.label, selection: text) {
                    if !field.options.contains(where: { $0.value == (values.first ?? "") }) {
                        Text(L10n.string("forum.native.choose")).tag("")
                    }
                    ForEach(field.options) { option in Text(option.label).tag(option.value) }
                }
            case .multipleChoice:
                VStack(alignment: .leading, spacing: 10) {
                    Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(field.options) { option in
                        Toggle(option.label, isOn: Binding(get: { values.contains(option.value) }, set: { selected in
                            values.removeAll { $0 == option.value }
                            if selected { values.append(option.value) }
                        }))
                    }
                }
            case .toggle:
                Toggle(field.label, isOn: Binding(get: { !values.isEmpty }, set: { values = $0 ? [field.options.first?.value ?? "on"] : [] }))
            case .file:
                Label(L10n.string("forum.native.upload_unavailable"), systemImage: "paperclip")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("native-form-field-\(field.name)")
    }
}
