import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import YamiboXCore

// Shared form interactions; business screens choose the composer form, while
// document-only pages never install editing, upload, or submission state.
struct ForumFormPageView: View {
    let model: ForumPageSession
    let document: ForumPageDocument
    let composerForm: ForumForm?
    @State private var imageRequest: ForumThreadImageBrowserRequest?
    @State private var fileSelection: FileSelection?
    @State private var showsFileImporter = false
    @State private var showsPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var photoSelection: PhotoSelection?
    @State private var isPreparingPhoto = false
    @State private var pendingUpload: PendingUpload?
    @State private var pendingNavigation: PendingNavigation?
    let editorRegistry: ForumEditorRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onURLTap: (URL) -> Void
    let onSubmissionSucceeded: ((TransientFeedback) -> Void)?
    let isEmbedded: Bool
    let onAttachmentActivityChanged: ((Bool) -> Void)?

    init(model: ForumPageSession, document: ForumPageDocument, composerForm: ForumForm?, editorRegistry: ForumEditorRegistry,
         onSubmissionSucceeded: ((TransientFeedback) -> Void)? = nil, isEmbedded: Bool = false,
         onAttachmentActivityChanged: ((Bool) -> Void)? = nil, onURLTap: @escaping (URL) -> Void) {
        self.model = model
        self.document = document
        self.composerForm = composerForm
        self.editorRegistry = editorRegistry
        self.onURLTap = onURLTap
        self.onSubmissionSucceeded = onSubmissionSucceeded
        self.isEmbedded = isEmbedded
        self.onAttachmentActivityChanged = onAttachmentActivityChanged
    }

    var body: some View {
        ZStack {
            content
        }
        .onChange(of: model.submissionSucceeded) { _, succeeded in
            guard succeeded, composerForm != nil, !isEmbedded else { return }
            let feedback = model.transientFeedback ?? TransientFeedback(message: L10n.string("forum.native.submitted"))
            model.transientFeedback = nil
            onSubmissionSucceeded?(feedback)
            dismiss()
        }
        .modifier(ForumFormNavigationProtection(isEmbedded: isEmbedded, isProtected: needsNavigationProtection))
        .toolbar {
            if !isEmbedded, needsNavigationProtection {
                ToolbarItem(placement: .topBarLeading) {
                    Button { editorRegistry.commitEditing(); pendingNavigation = .back } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel(L10n.string("common.back"))
                        .disabled(model.isSubmitting || model.isUploading)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if !isEmbedded, let form = composerForm, let button = primaryButton(form) {
                    Button { prepareSubmission(form: form, button: button) } label: {
                        Label(button.title, systemImage: "paperplane.fill")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("native-form-submit-\(button.id)")
                    .disabled(formDisabled)
                }
            }
            if !isEmbedded, composerForm == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await model.refresh() } } label: {
                            Label(L10n.string("common.refresh"), systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isLoading || model.isSubmitting || model.isUploading || isPreparingPhoto)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(L10n.string("forum.native.more_actions"))
                }
            }
        }
        .confirmationDialog(
            model.pendingSubmission?.title ?? L10n.string("common.confirm"),
            isPresented: Binding(get: { !isEmbedded && model.pendingSubmission != nil }, set: { if !$0 { model.pendingSubmission = nil } }),
            titleVisibility: .visible
        ) {
            if let submission = model.pendingSubmission {
                Button(submission.title, role: submission.form.isDestructive ? .destructive : nil) {
                    Task { await model.confirmSubmission(submission) }
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) { model.pendingSubmission = nil }
        } message: {
            Text(L10n.string("forum.native.confirm_submit"))
        }
        .confirmationDialog(L10n.string("forum.native.discard_title"), isPresented: Bindable(model).showsDiscardConfirmation, titleVisibility: .visible) {
            Button(L10n.string("forum.native.discard_reload"), role: .destructive) {
                Task { await model.refresh(discardingEdits: true) }
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        }
        .fullScreenCover(item: $imageRequest) { request in
            ImageBrowserView(items: request.items, initialItemID: request.initialItemID, mode: .single) { imageRequest = nil }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item]) { result in
            importFile(result)
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoPickerItem, matching: .images, preferredItemEncoding: .current)
        .task(id: photoPickerItem) {
            guard let item = photoPickerItem, let selection = photoSelection else { return }
            await importPhoto(item, selection: selection)
        }
        .onChange(of: isPreparingPhoto) { _, value in onAttachmentActivityChanged?(value) }
        .onDisappear {
            onAttachmentActivityChanged?(false)
            editorRegistry.commitEditing()
            Task { _ = await model.flushLocalDraft() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { editorRegistry.commitEditing(); Task { await model.flushLocalDraftInBackground() } }
        }
        .task(id: composerForm?.id) {
            model.connectEditors(editorRegistry)
        }
        .task { await model.composerDraft?.observeIdentity() }
        .environment(\.forumComposerImageUpload, imageUploadAction)
        .sheet(isPresented: Bindable(model).showsDrafts) { ForumComposerDraftList(model: model) }
        .confirmationDialog(L10n.string("forum.native.upload"), isPresented: Binding(
            get: { pendingUpload != nil && !showsPhotoPicker && !isPreparingPhoto }, set: { if !$0 { pendingUpload = nil } }
        ), titleVisibility: .visible) {
            if let upload = pendingUpload {
                Button(L10n.string("forum.native.upload")) {
                    pendingUpload = nil
                    let editor = upload.form.fields.first(where: { $0.name == "message" }).map { editorRegistry.controller(for: $0.id).bbcodeSession }
                    Task { await model.upload(file: upload.file, mimeType: upload.mimeType, configuration: upload.configuration, form: upload.form, editor: upload.form.kind == .thread ? editor : nil) }
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) { pendingUpload = nil }
        } message: {
            if let upload = pendingUpload {
                Text(uploadConfirmation(upload))
            }
        }
        .confirmationDialog(L10n.string("forum.native.discard_title"), isPresented: Binding(
            get: { pendingNavigation != nil }, set: { if !$0 { pendingNavigation = nil } }
        ), titleVisibility: .visible) {
            if composerForm?.kind == .thread, model.composerDraft?.active == true {
                Button(L10n.string("forum.composer.keep_draft_leave")) {
                    let navigation = pendingNavigation
                    Task {
                        guard await model.flushLocalDraft(force: true) else { return }
                        finishNavigation(navigation)
                    }
                }
            }
            Button(L10n.string("forum.native.discard_leave"), role: .destructive) {
                let navigation = pendingNavigation
                Task {
                    guard await model.discardLocalDraft() else { return }
                    finishNavigation(navigation)
                }
            }
            Button(L10n.string("common.cancel"), role: .cancel) { pendingNavigation = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        let page = document
        let list = List {
            if model.isOfflineDraft {
                Section {
                    Label(L10n.string("forum.composer.local_edit"), systemImage: "wifi.slash").foregroundStyle(.secondary)
                    Button(L10n.string("forum.composer.reload_form"), systemImage: "arrow.clockwise") {
                        if let draft = model.composerDraft?.current { Task { await model.restoreDraft(draft) } }
                    }
                }
            }
            ForumDocumentSections(document: page, onImageTap: showImage, onURLTap: navigate)
            ForEach(isEmbedded ? composerForm.map { [$0] } ?? [] : page.forms) { form in
                ForumFormSection(
                    form: form,
                    values: Binding(get: { model.drafts[form.id] ?? form.initialValues }, set: { model.drafts[form.id] = $0 }),
                    htmlSourceFields: Bindable(model).htmlSourceFields,
                    files: Binding(get: { model.selectedFiles[form.id] ?? [] }, set: { model.setSelectedFiles($0, form: form) }),
                    uploads: page.uploads.filter { form.kind == .blog ? $0.kind == .blogImage : form.kind == .thread && $0.kind != .blogImage },
                    attachments: (model.attachments[form.id] ?? []).filter { attachment in !model.composerAssets.contains { $0.uploadID == attachment.id } },
                    disabled: formDisabled,
                    onChooseFile: { field, configuration in
                        editorRegistry.commitEditing()
                        if let configuration, configuration.kind != .threadAttachment {
                            photoPickerItem = nil
                            photoSelection = PhotoSelection(form: form, configuration: configuration)
                            showsPhotoPicker = true
                        } else {
                            fileSelection = FileSelection(form: form, field: field, configuration: configuration)
                            showsFileImporter = true
                        }
                    },
                    onSubmit: { prepareSubmission(form: form, button: $0) },
                    onURLTap: navigate,
                    editorRegistry: editorRegistry,
                    composerContext: model.composerContext(for: form),
                    editorDisabled: model.isLoading || model.isSubmitting || model.submissionSucceeded,
                    onDrafts: form.kind == .thread && model.composerDraft?.active == true ? { Task { await model.openDrafts() } } : nil,
                    draftStatus: model.composerDraft?.statusText
                )
                if form.kind == .thread { ForumComposerAssetSection(model: model, form: form) }
            }
            if model.isSubmitting {
                Section { ProgressView(L10n.string("forum.native.submitting")) }
            }
            if model.isUploading {
                Section { ProgressView(L10n.string("forum.native.uploading")) }
            }
            if isPreparingPhoto {
                Section { ProgressView(L10n.string("forum.native.preparing_image")) }
            }
            if let url = model.submissionResponse?.continuationURL, composerForm == nil {
                Section {
                    Button { navigate(url) } label: {
                        Label(L10n.string("forum.native.continue"), systemImage: "arrow.right")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        if isEmbedded {
            list.listStyle(.plain)
        } else if composerForm == nil {
            list.listStyle(.insetGrouped).refreshable { if !isPreparingPhoto { await model.refresh() } }
        } else {
            list.listStyle(.insetGrouped)
        }
    }

    private var formDisabled: Bool { model.isLoading || model.isSubmitting || model.isUploading || model.submissionSucceeded || isPreparingPhoto || model.isOfflineDraft }

    private func finishNavigation(_ navigation: PendingNavigation?) {
        pendingNavigation = nil
        if case let .url(url) = navigation { onURLTap(url) }
        else { dismiss() }
    }

    private func primaryButton(_ form: ForumForm) -> ForumFormButton? {
        form.buttons.first { !$0.values.contains { $0.name == "save" && $0.value == "1" } } ?? form.buttons.first
    }

    private func prepareSubmission(form: ForumForm, button: ForumFormButton) {
        editorRegistry.prepareSubmission(form: form, button: button, model: model)
    }

    private func showImage(_ id: String, _ url: URL, _ title: String?, _ referer: URL) {
        imageRequest = ForumThreadImageBrowserRequest(
            items: [ImageBrowserItem(id: id, source: YamiboImageSource(url: url, refererPageURL: referer), title: title ?? model.page?.title ?? "")],
            initialItemID: id
        )
    }

    private struct FileSelection {
        let form: ForumForm
        let field: ForumFormField?
        let configuration: ForumUploadConfiguration?
    }

    private var imageUploadAction: ForumComposerImageUploadAction? {
        guard let form = composerForm, form.kind == .thread, !model.isOfflineDraft,
              let configuration = document.uploads.first(where: { $0.kind == .threadImage }) else { return nil }
        let draftID = model.composerDraft?.current?.id
        return .init(configuration: configuration, isBusy: model.isUploading || model.isSubmitting) { [weak model] image, editor in
            guard let model, model.composerDraft?.current?.id == draftID else { return }
            await model.upload(file: image.file, mimeType: image.mimeType, configuration: configuration, form: form, editor: editor)
        }
    }

    private enum PendingNavigation {
        case back
        case url(URL)
    }

    private func navigate(_ url: URL) {
        guard !model.isSubmitting, !model.isUploading else { return }
        editorRegistry.commitEditing()
        if !isEmbedded, model.hasEdits && !model.submissionSucceeded { pendingNavigation = .url(url) }
        else { onURLTap(url) }
    }

    private var needsNavigationProtection: Bool {
        let composing = composerForm?.fields.filter { $0.name == "message" }.contains {
            editorRegistry.controller(for: $0.id).bbcodeSession.isComposing
        } ?? false
        return model.hasEdits || model.isSubmitting || model.isUploading || composing
    }

    private struct PendingUpload {
        let form: ForumForm
        let configuration: ForumUploadConfiguration
        let file: ForumAttachmentFile
        let mimeType: String
        var wasConverted = false
    }

    private struct PhotoSelection {
        let form: ForumForm
        let configuration: ForumUploadConfiguration
    }

    private func importPhoto(_ item: PhotosPickerItem, selection: PhotoSelection) async {
        isPreparingPhoto = true
        model.clearError()
        defer { isPreparingPhoto = false }
        do {
            guard let pickedImage = try await item.loadTransferable(type: ForumPickedImage.self) else { throw ForumUploadImageError.invalidImage }
            try Task.checkCancellation()
            let image = try await ForumUploadImageProcessor.shared.prepare(pickedImage.data, configuration: selection.configuration)
            try Task.checkCancellation()
            pendingUpload = PendingUpload(form: selection.form, configuration: selection.configuration,
                                          file: image.file, mimeType: image.mimeType, wasConverted: image.wasConverted)
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) { model.reportFileError(error) }
        }
    }

    private func uploadConfirmation(_ upload: PendingUpload) -> String {
        var lines = [upload.file.name, Int64(upload.file.data.count).formatted(.byteCount(style: .file))]
        if upload.wasConverted { lines.append(L10n.string("forum.native.image_converted", upload.mimeType == "image/png" ? "PNG" : "JPEG")) }
        return lines.joined(separator: "\n") + "\n\n" + L10n.string("forum.native.confirm_upload")
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard let selection = fileSelection else { return }
        fileSelection = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let limit = min(selection.configuration?.maximumBytes ?? 5 * 1024 * 1024, 5 * 1024 * 1024)
            guard size <= limit else { throw ForumPageError.fileTooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= limit else { throw ForumPageError.fileTooLarge }
            let file = ForumAttachmentFile(name: url.lastPathComponent, data: data)
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            if let configuration = selection.configuration {
                pendingUpload = PendingUpload(form: selection.form, configuration: configuration, file: file, mimeType: mimeType)
            } else if let field = selection.field {
                Task { await model.stageFormFile(.init(fieldName: field.name, file: file, mimeType: mimeType), form: selection.form) }
            }
        } catch { model.reportFileError(error) }
    }
}

private struct ForumFormNavigationProtection: ViewModifier {
    let isEmbedded: Bool
    let isProtected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content.navigationBarBackButtonHidden(isProtected).interactiveDismissDisabled(isProtected)
        }
    }
}
