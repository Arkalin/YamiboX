import Foundation
import Observation
import UIKit
import YamiboXCore

protocol ForumPageLoading: Sendable {
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment
}

extension ForumPageRepository: ForumPageLoading {}

@MainActor
@Observable
final class ForumPageSession {
    let url: URL
    private(set) var page: ForumPageDocument?
    var navigationResult: ForumPageLoadResult?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var errorDetails: LoadFailureDetails?
    var errorMessage: String?
    var transientFeedback: TransientFeedback?
    var drafts: [String: [String: [String]]] = [:] { didSet { synchronizeLocalDraft() } }
    var htmlSourceFields: Set<String> = []
    var pendingSubmission: Submission?
    var showsDiscardConfirmation = false
    var selectedFiles: [String: [ForumFormFile]] = [:]
    private(set) var attachments: [String: [ForumUploadedAttachment]] = [:]
    private(set) var isUploading = false
    private(set) var submissionResponse: ForumPageDocument?
    private(set) var submissionSucceeded = false
    private(set) var requiresLoadConfirmation: Bool
    let composerDraft: ForumComposerDraftCoordinator?
    private(set) var isOfflineDraft = false
    var showsDrafts = false
    var draftConflict: DraftConflict?
    private(set) var composerAssets: [ForumComposerDraftAttachment] = []
    private(set) var assetFailures: [UUID: String] = [:]
    private(set) var uploadingAssetID: UUID?
    @ObservationIgnored private let sessionStore: SessionStore?
    @ObservationIgnored private var pageGeneration: UUID?
    @ObservationIgnored private var activeEditorURL: URL?
    @ObservationIgnored private weak var editorRegistry: ForumEditorRegistry?
    @ObservationIgnored private var assetFiles: [UUID: ForumAttachmentFile] = [:]
    @ObservationIgnored private var assetAnchors: [UUID: UUID] = [:]
    @ObservationIgnored private var suppressDraftUpdates = false

    struct DraftConflict: Identifiable {
        let id = UUID()
        let draft: ForumComposerDraft
        let page: ForumPageDocument
        let accountGeneration: UUID?
    }

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumPageLoading
    @ObservationIgnored private var lastConfirmedSubmissionID: UUID?
    @ObservationIgnored private let onSubmissionAccepted: ((ForumSubmissionChange) -> Void)?

    struct Submission: Identifiable {
        let id = UUID()
        let form: ForumForm
        let buttonID: String
        let title: String
        let values: [String: [String]]
        let files: [ForumFormFile]
        let attachments: [ForumUploadedAttachment]
        var draftID: UUID?
        var draftChangeID: UInt64?
        var accountGeneration: UUID?
    }

    init(url: URL, dependencies: ForumDependencies, onSubmissionAccepted: ((ForumSubmissionChange) -> Void)? = nil) {
        self.url = url
        self.onSubmissionAccepted = onSubmissionAccepted
        sessionStore = dependencies.sessionStore
        composerDraft = dependencies.composerDraftStore.map { ForumComposerDraftCoordinator(store: $0, sessionStore: dependencies.sessionStore) }
        requiresLoadConfirmation = ForumWebPagePolicy.requiresConfirmationToLoad(url)
        repositoryProvider = { await dependencies.makePageRepository() }
    }

    init(url: URL, repository: any ForumPageLoading, sessionStore: SessionStore? = nil, draftStore: (any ForumComposerDraftPersisting)? = nil,
         onSubmissionAccepted: ((ForumSubmissionChange) -> Void)? = nil) {
        self.url = url
        self.onSubmissionAccepted = onSubmissionAccepted
        self.sessionStore = sessionStore
        composerDraft = if let sessionStore, let draftStore { ForumComposerDraftCoordinator(store: draftStore, sessionStore: sessionStore) } else { nil }
        requiresLoadConfirmation = ForumWebPagePolicy.requiresConfirmationToLoad(url)
        repositoryProvider = { repository }
    }

    var hasEdits: Bool {
        guard let page, !submissionSucceeded else { return false }
        return !composerAssets.isEmpty || isOfflineDraft || selectedFiles.values.contains { !$0.isEmpty } || attachments.values.contains { !$0.isEmpty } ||
            page.forms.contains { (drafts[$0.id] ?? $0.initialValues) != $0.initialValues }
    }

    func load(confirmedAction: Bool = false) async {
        guard !isLoading, !isSubmitting, !isUploading, page == nil,
              confirmedAction || !requiresLoadConfirmation else { return }
        isLoading = true
        clearError()
        defer { isLoading = false }
        do {
            let generation = try await sessionStore?.snapshot().generation
            let repository = await repositoryProvider()
            let response = try await repository.fetchPage(url: activeEditorURL ?? url, confirmedAction: confirmedAction)
            try Task.checkCancellation()
            try await checkGeneration(generation)
            pageGeneration = generation
            guard case let .page(result) = response else {
                navigationResult = response
                // Embedded composers cannot navigate; leave them a retryable
                // failure rather than a permanently empty loading surface.
                setError(ForumPageError.invalidForm)
                return
            }
            page = result
            drafts = Dictionary(uniqueKeysWithValues: result.forms.map { ($0.id, $0.initialValues) })
            htmlSourceFields = Set(result.forms.filter { $0.kind == .blog }.flatMap { form in
                form.fields.filter { $0.name == "message" && $0.initialValues.first?.isEmpty == false }.map(\.id)
            })
            requiresLoadConfirmation = false
            if let form = result.forms.first(where: { $0.kind == .thread }) {
                await composerDraft?.start(form: form, context: result.composerContext ?? .init())
                installDraftCallbacks()
            }
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                setError(error)
                if ForumPostEditorMode(url: url) != nil, composerDraft?.current == nil {
                    let placeholder = ForumForm(id: "draft-list", title: "", actionURL: url, kind: .thread)
                    await composerDraft?.start(form: placeholder, context: .init())
                    installDraftCallbacks()
                }
            }
        }
    }

    func refresh(discardingEdits: Bool = false) async {
        guard !isLoading, !isSubmitting, !isUploading else { return }
        if hasEdits && !discardingEdits {
            showsDiscardConfirmation = true
            return
        }
        if discardingEdits, !(await discardLocalDraft()) { return }
        // Confirmation is per request, not a permanent authorization that a
        // refresh can reuse for destructive GET actions.
        requiresLoadConfirmation = ForumWebPagePolicy.requiresConfirmationToLoad(url)
        page = nil
        drafts = [:]
        selectedFiles = [:]
        attachments = [:]
        composerAssets = []; assetFiles = [:]; assetAnchors = [:]; assetFailures = [:]
        isOfflineDraft = false
        submissionResponse = nil
        submissionSucceeded = false
        await load()
    }

    func prepareSubmission(form: ForumForm, button: ForumFormButton) {
        guard !isLoading, !isSubmitting, !isUploading, !submissionSucceeded else { return }
        guard !isOfflineDraft else { errorMessage = L10n.string("forum.composer.offline_send"); return }
        guard !composerAssets.contains(where: { $0.uploadID == nil && $0.fieldName == nil }) else {
            errorMessage = L10n.string("forum.composer.pending_attachments"); return
        }
        do {
            var values = drafts[form.id] ?? form.initialValues
            if form.kind == .blog {
                for field in form.fields where field.name == "message" && !htmlSourceFields.contains(field.id) {
                    values[field.id] = [Self.htmlFromPlainText(values[field.id]?.first ?? "")]
                }
            }
            _ = try form.submissionValues(values: values, buttonID: button.id)
            let files = selectedFiles[form.id] ?? []
            for field in form.fields where field.kind == .file && field.isRequired {
                guard files.contains(where: { $0.fieldName == field.name }) else {
                    throw ForumPageError.requiredField(field.label)
                }
            }
            pendingSubmission = Submission(form: form, buttonID: button.id, title: button.title, values: values,
                                           files: files, attachments: attachments[form.id] ?? [], draftID: composerDraft?.current?.id,
                                           draftChangeID: composerDraft?.changeID, accountGeneration: pageGeneration)
            clearError()
        } catch { setError(error) }
    }

    /// Refresh server tokens after login without replacing the user's composer draft.
    func reloadComposerPreservingEdits() async {
        if isOfflineDraft, let draft = composerDraft?.current {
            await restoreDraft(draft)
            return
        }
        guard let previous = page, !isLoading, !isSubmitting, !isUploading, !submissionSucceeded,
              !requiresLoadConfirmation else { return }
        isLoading = true
        clearError()
        defer { isLoading = false }
        do {
            let generation = try await sessionStore?.snapshot().generation
            let repository = await repositoryProvider()
            let response = try await repository.fetchPage(url: activeEditorURL ?? url, confirmedAction: false)
            try Task.checkCancellation()
            try await checkGeneration(generation)
            guard case let .page(refreshed) = response else { throw ForumPageError.invalidForm }
            guard refreshed.forms.contains(where: { $0.kind == .thread && $0.fields.contains(where: { $0.name == "message" }) }) else {
                throw YamiboError.underlying(refreshed.message ?? ForumPageError.invalidForm.localizedDescription)
            }
            var refreshedDrafts: [String: [String: [String]]] = [:]
            var refreshedFiles: [String: [ForumFormFile]] = [:]
            var refreshedAttachments: [String: [ForumUploadedAttachment]] = [:]
            var refreshedSourceFields: Set<String> = []
            for form in refreshed.forms {
                var values = form.initialValues
                if let oldForm = previous.forms.first(where: { $0.kind == form.kind && $0.id == form.id })
                    ?? previous.forms.first(where: { $0.kind == form.kind && form.kind == .thread }) {
                    for field in form.fields where !field.isReadOnly {
                        guard let oldField = oldForm.fields.first(where: { $0.name == field.name }) else { continue }
                        let draft = drafts[oldForm.id]?[oldField.id] ?? oldField.initialValues
                        if draft != oldField.initialValues { values[field.id] = draft }
                        if htmlSourceFields.contains(oldField.id) { refreshedSourceFields.insert(field.id) }
                    }
                    refreshedFiles[form.id] = selectedFiles[oldForm.id]
                    refreshedAttachments[form.id] = attachments[oldForm.id]
                }
                refreshedDrafts[form.id] = values
            }
            page = refreshed
            pageGeneration = generation
            isOfflineDraft = false
            drafts = refreshedDrafts
            selectedFiles = refreshedFiles
            attachments = refreshedAttachments
            htmlSourceFields = refreshedSourceFields
            pendingSubmission = nil
            submissionResponse = nil
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) { setError(error) }
        }
    }

    func confirmSubmission(_ submission: Submission? = nil) async {
        // Dialog dismissal can clear presentation state before this task runs.
        // Consume the confirmed snapshot once, independently of that state.
        guard let pending = submission ?? pendingSubmission, let page,
              !isLoading, !isSubmitting, !isUploading, !submissionSucceeded,
              !isOfflineDraft,
              lastConfirmedSubmissionID != pending.id else { return }
        lastConfirmedSubmissionID = pending.id
        pendingSubmission = nil
        isSubmitting = true
        clearError()
        defer { isSubmitting = false }
        do {
            try await checkGeneration(pending.accountGeneration)
            _ = await composerDraft?.flush()
            let repository = await repositoryProvider()
            try await checkGeneration(pending.accountGeneration)
            let response = try await repository.submit(
                form: pending.form, values: pending.values, buttonID: pending.buttonID, referer: page.url,
                files: pending.files, attachments: pending.attachments
            )
            try await checkGeneration(pending.accountGeneration)
            try Task.checkCancellation()
            guard case let .page(result) = response else {
                guard pending.form.method == "GET" else { throw ForumPageError.submissionUnconfirmed }
                navigationResult = response
                return
            }
            if pending.form.method == "GET" {
                self.page = result
                drafts = Dictionary(uniqueKeysWithValues: result.forms.map { ($0.id, $0.initialValues) })
                submissionResponse = nil
                return
            }
            submissionResponse = result
            // An arbitrary nonempty page is not evidence of success. Keep the
            // draft after permission errors, validation failures and ambiguous
            // responses; never resend automatically after a timeout.
            let message = result.message ?? ""
            let isServerDraft = pending.form.kind == .thread && pending.form.buttons.first(where: { $0.id == pending.buttonID })?.values.contains(where: { $0.name == "save" && $0.value == "1" }) == true
            submissionSucceeded = result.submissionAccepted && !isServerDraft
            if result.submissionAccepted {
                if let id = pending.draftID, let changeID = pending.draftChangeID {
                    await composerDraft?.removeSubmitted(id: id, changeID: changeID, serverDraft: isServerDraft)
                }
                if !isServerDraft, let change = ForumSubmissionChange(form: pending.form, sourceURL: page.url, response: result) {
                    onSubmissionAccepted?(change)
                }
                transientFeedback = TransientFeedback(message: message.isEmpty ? L10n.string("forum.native.submitted") : message)
            } else {
                let failure = message.isEmpty ? ForumPageError.submissionUnconfirmed.localizedDescription : message
                errorMessage = failure
                transientFeedback = .failure(failure)
            }
        } catch {
            if !LoadDiagnosticError.isCancellation(error) { setError(error) }
        }
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, form: ForumForm,
                editor: ForumBBCodeSession? = nil, assetID: UUID? = nil) async {
        guard let page, !isSubmitting, !isUploading,
              page.forms.contains(form),
              let body = form.fields.first(where: { $0.name == "message" }) else { return }
        guard !isOfflineDraft else { errorMessage = L10n.string("forum.composer.offline_send"); return }
        isUploading = true
        clearError()
        let generation = pageGeneration
        let draftID = composerDraft?.current?.id
        let initialAnchor = form.kind == .thread && assetID == nil ? editor?.bookmark() : nil
        var pendingID: UUID?
        defer {
            isUploading = false; uploadingAssetID = nil
            if pendingID == nil, let initialAnchor { editor?.removeBookmark(initialAnchor) }
        }
        do {
            try await checkGeneration(generation)
            if form.kind == .thread {
                let id = assetID ?? UUID()
                pendingID = id; uploadingAssetID = id
                if assetID == nil {
                    let anchor = initialAnchor
                    if let anchor { assetAnchors[id] = anchor }
                    composerAssets.append(.init(id: id, name: file.name, mimeType: mimeType, isImage: configuration.kind == .threadImage,
                                                anchor: anchor.flatMap { editor?.bookmarkedSelection($0) }))
                }
                assetFiles[id] = file
                assetFailures[id] = nil
                if let index = composerAssets.firstIndex(where: { $0.id == id }), composerAssets[index].resourceID == nil,
                   let composerDraft, composerDraft.active {
                    let resource = try await composerDraft.importResource(file)
                    guard let liveIndex = composerAssets.firstIndex(where: { $0.id == id }), composerDraft.current?.id == draftID else { return }
                    composerAssets[liveIndex].resourceID = resource
                }
                synchronizeLocalDraft()
                _ = await composerDraft?.flush()
            }
            let repository = await repositoryProvider()
            try await checkGeneration(generation)
            let result = try await repository.upload(file: file, mimeType: mimeType, configuration: configuration, referer: page.url)
            try await checkGeneration(generation)
            guard composerDraft?.current?.id == draftID else { return }
            if let pendingID, !composerAssets.contains(where: { $0.id == pendingID }) { return }
            attachments[form.id, default: []].append(result)
            if form.kind == .thread, let pendingID, let index = composerAssets.firstIndex(where: { $0.id == pendingID }) {
                composerAssets[index].uploadID = result.id
                if let editor {
                    if configuration.kind == .threadImage, let image = UIImage(data: file.data) {
                        editor.localImages[result.id] = image
                        editorRegistry?.controller(for: body.id).bbcodeSession.localImages[result.id] = image
                    }
                    let inserted = assetAnchors[pendingID].map { editor.insertMarkup(result.markup, at: $0) } ?? false
                    composerAssets[index].inserted = inserted
                    composerAssets[index].anchor = nil
                    assetAnchors[pendingID] = nil
                    synchronizeLocalDraft()
                    return
                }
                composerAssets[index].inserted = true
            }
            var values = drafts[form.id] ?? form.initialValues
            var text = values[body.id]?.first ?? ""
            if form.kind == .blog && !htmlSourceFields.contains(body.id) {
                text = Self.htmlFromPlainText(text)
                htmlSourceFields.insert(body.id)
            }
            values[body.id] = [text + "\n" + result.markup]
            drafts[form.id] = values
        } catch {
            if let pendingID, composerDraft?.current?.id == draftID, composerAssets.contains(where: { $0.id == pendingID }) {
                assetFailures[pendingID] = error.localizedDescription
                synchronizeLocalDraft()
            }
            if !LoadDiagnosticError.isCancellation(error) { setError(error) }
        }
    }

    func connectEditors(_ registry: ForumEditorRegistry) {
        editorRegistry = registry
        installDraftCallbacks()
        guard let form = page?.forms.first(where: { $0.kind == .thread }), let field = form.fields.first(where: { $0.name == "message" }) else { return }
        let editor = registry.controller(for: field.id).bbcodeSession
        editor.refererURL = page?.url ?? YamiboDomain.baseURL
        editor.onStateChange = { [weak self] _, _ in self?.synchronizeLocalDraft() }
        if let draft = composerDraft?.current, !registry.controller(for: field.id).hasRestoredDraftState {
            registry.controller(for: field.id).hasRestoredDraftState = true
            editor.restoreState(sourceMode: draft.sourceMode, selection: draft.selection)
        }
    }

    private func installDraftCallbacks() {
        composerDraft?.onCommitEditing = { [weak self] in
            self?.editorRegistry?.commitEditing()
            self?.synchronizeLocalDraft()
        }
        composerDraft?.onInvalidated = { [weak self] in
            guard let self else { return }
            suppressDraftUpdates = true
            editorRegistry?.clear()
            page = nil; drafts = [:]; selectedFiles = [:]; attachments = [:]
            composerAssets = []; assetFiles = [:]; assetFailures = [:]; assetAnchors = [:]
            pendingSubmission = nil; submissionResponse = nil; draftConflict = nil; showsDrafts = false
            isOfflineDraft = false
            errorMessage = L10n.string("forum.composer.account_changed")
            suppressDraftUpdates = false
        }
    }

    func synchronizeLocalDraft() {
        guard !suppressDraftUpdates, let form = page?.forms.first(where: { $0.kind == .thread }) else { return }
        let editor = form.fields.first(where: { $0.name == "message" }).flatMap { editorRegistry?.controller(for: $0.id).bbcodeSession }
        for index in composerAssets.indices {
            if let anchor = assetAnchors[composerAssets[index].id] { composerAssets[index].anchor = editor?.bookmarkedSelection(anchor) }
        }
        composerDraft?.update(form: form, values: drafts[form.id] ?? form.initialValues, sourceMode: editor?.sourceMode,
                              selection: editor?.selection, attachments: composerAssets, retainingMissingFields: isOfflineDraft)
    }

    func flushLocalDraft(force: Bool = false) async -> Bool {
        editorRegistry?.commitEditing()
        synchronizeLocalDraft()
        guard let composerDraft else { return true }
        return await composerDraft.flush(force: force)
    }

    func flushLocalDraftInBackground() async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "Forum draft save", expirationHandler: nil)
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        _ = await flushLocalDraft()
    }

    func discardLocalDraft() async -> Bool {
        guard let composerDraft, let draft = composerDraft.current else { return true }
        return await composerDraft.delete(draft)
    }

    func openDrafts() async {
        _ = await flushLocalDraft()
        await composerDraft?.reloadList()
        showsDrafts = true
    }

    func deleteDraft(_ draft: ForumComposerDraft) async {
        guard let composerDraft else { return }
        let isCurrent = composerDraft.current?.id == draft.id
        guard await composerDraft.delete(draft) else { return }
        if isCurrent, let page, let form = page.forms.first(where: { $0.kind == .thread }) {
            suppressDraftUpdates = true
            editorRegistry?.clear()
            drafts[form.id] = form.initialValues
            composerAssets = []; assetFiles = [:]; assetAnchors = [:]; assetFailures = [:]
            attachments = [:]; selectedFiles = [:]
            suppressDraftUpdates = false
            await composerDraft.start(form: form, context: page.composerContext ?? .init())
            if let editorRegistry { connectEditors(editorRegistry) }
        } else { await composerDraft.reloadList() }
    }

    func restoreDraft(_ requested: ForumComposerDraft) async {
        guard !isLoading, !isSubmitting, !isUploading, let composerDraft else { return }
        guard await flushLocalDraft() else { return }
        await composerDraft.reloadList()
        guard let draft = composerDraft.available.first(where: { $0.id == requested.id }), let targetURL = draft.target.editorURL else {
            errorMessage = L10n.string("forum.composer.draft_deleted"); return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let generation = try await sessionStore?.snapshot().generation
            let repository = await repositoryProvider()
            let response = try await repository.fetchPage(url: targetURL, confirmedAction: false)
            try await checkGeneration(generation)
            guard case let .page(document) = response else { throw ForumPageError.invalidForm }
            guard let form = document.forms.first(where: { $0.kind == .thread }) else { throw ForumPageError.invalidForm }
            if [.editFirstPost, .editReply].contains(draft.target.kind), !draft.baseline.isEmpty,
               ForumComposerDraft.fingerprint(form: form) != draft.baseline {
                draftConflict = .init(draft: draft, page: document, accountGeneration: generation)
                return
            }
            await installRestoredDraft(draft, document: document, generation: generation)
        } catch {
            guard composerDraft.active, !LoadDiagnosticError.isCancellation(error) else { return }
            let fields = [ForumFormField(id: "offline-subject", name: "subject", label: L10n.string("forum.composer.title"), initialValues: [draft.title]),
                          ForumFormField(id: "offline-message", name: "message", label: L10n.string("forum.native.message"), kind: .multiline, initialValues: [draft.source])]
            let form = ForumForm(id: "offline-draft", title: draft.title, actionURL: targetURL, kind: .thread, fields: fields)
            let document = ForumPageDocument(url: targetURL, title: L10n.string("forum.composer.local_edit"), forms: [form], composerContext: .init(target: draft.target))
            await installRestoredDraft(draft, document: document, generation: pageGeneration, offline: true)
            setError(error)
        }
    }

    func resolveDraftConflict(useLocal: Bool) async {
        guard let conflict = draftConflict, let form = conflict.page.forms.first(where: { $0.kind == .thread }) else { return }
        do { try await checkGeneration(conflict.accountGeneration) }
        catch { draftConflict = nil; return }
        draftConflict = nil
        let generation = conflict.accountGeneration
        if useLocal { await installRestoredDraft(conflict.draft, document: conflict.page, generation: generation) }
        else {
            suppressDraftUpdates = true
            editorRegistry?.clear()
            page = conflict.page; activeEditorURL = conflict.page.url; pageGeneration = generation
            drafts = Dictionary(uniqueKeysWithValues: conflict.page.forms.map { ($0.id, $0.initialValues) })
            selectedFiles = [:]; attachments = [:]; composerAssets = []; assetFiles = [:]; assetAnchors = [:]; assetFailures = [:]
            isOfflineDraft = false; showsDrafts = false
            suppressDraftUpdates = false
            await composerDraft?.start(form: form, context: conflict.page.composerContext ?? .init())
            if let editorRegistry { connectEditors(editorRegistry) }
        }
    }

    private func installRestoredDraft(_ draft: ForumComposerDraft, document: ForumPageDocument, generation: UUID?, offline: Bool = false) async {
        guard let form = document.forms.first(where: { $0.kind == .thread }), let composerDraft else { return }
        await composerDraft.start(form: form, context: document.composerContext ?? .init(target: draft.target), restoring: draft)
        guard composerDraft.active, composerDraft.current?.id == draft.id else { return }
        if !offline {
            do { try await checkGeneration(generation) }
            catch { return }
        }
        suppressDraftUpdates = true
        editorRegistry?.clear()
        page = document; pageGeneration = generation; activeEditorURL = draft.target.editorURL
        isOfflineDraft = offline
        drafts = Dictionary(uniqueKeysWithValues: document.forms.map { ($0.id, $0.kind == .thread ? ForumComposerDraftFields.restoring(draft.fields, into: $0) : $0.initialValues) })
        selectedFiles = [:]; attachments = [form.id: draft.attachments.compactMap(\.uploadedAttachment)]
        composerAssets = draft.attachments; assetFiles = [:]; assetAnchors = [:]; assetFailures = [:]
        pendingSubmission = nil; submissionResponse = nil; submissionSucceeded = false; showsDrafts = false
        if let editorRegistry, let field = form.fields.first(where: { $0.name == "message" }) {
            let editor = editorRegistry.controller(for: field.id).bbcodeSession
            editor.load(draft.source)
            editor.restoreState(sourceMode: draft.sourceMode, selection: draft.selection)
            for asset in draft.attachments {
                if let anchor = asset.anchor { assetAnchors[asset.id] = editor.bookmark(selection: anchor) }
            }
            connectEditors(editorRegistry)
        }
        suppressDraftUpdates = false
        for asset in draft.attachments {
            guard composerDraft.current?.id == draft.id else { return }
            if let resource = asset.resourceID {
                do {
                    let file = try await composerDraft.resource(resource)
                    guard composerDraft.current?.id == draft.id else { return }
                    assetFiles[asset.id] = file
                    if let fieldName = asset.fieldName { selectedFiles[form.id, default: []].append(.init(fieldName: fieldName, file: file, mimeType: asset.mimeType)) }
                    if let uploadID = asset.uploadID, asset.isImage, let image = UIImage(data: file.data), let field = form.fields.first(where: { $0.name == "message" }) {
                        editorRegistry?.controller(for: field.id).bbcodeSession.localImages[uploadID] = image
                    }
                } catch { assetFailures[asset.id] = L10n.string("forum.composer.missing_resource") }
            } else if asset.uploadID == nil { assetFailures[asset.id] = L10n.string("forum.composer.missing_resource") }
        }
    }

    func retryAsset(_ id: UUID, form: ForumForm) async {
        guard let asset = composerAssets.first(where: { $0.id == id }), asset.uploadID == nil,
              let configuration = page?.uploads.first(where: { asset.isImage ? $0.kind == .threadImage : $0.kind == .threadAttachment }) else { return }
        do {
            let file: ForumAttachmentFile
            if let existing = assetFiles[id] { file = existing }
            else if let resource = asset.resourceID, let composerDraft { file = try await composerDraft.resource(resource) }
            else { throw ForumComposerDraftError.missingResource }
            let editor = form.fields.first(where: { $0.name == "message" }).flatMap { editorRegistry?.controller(for: $0.id).bbcodeSession }
            await upload(file: file, mimeType: asset.mimeType, configuration: configuration, form: form, editor: editor, assetID: id)
        } catch { assetFailures[id] = error.localizedDescription }
    }

    func insertAsset(_ id: UUID, form: ForumForm) {
        guard let index = composerAssets.firstIndex(where: { $0.id == id }), let attachment = composerAssets[index].uploadedAttachment,
              let field = form.fields.first(where: { $0.name == "message" }), let editorRegistry else { return }
        composerAssets[index].inserted = editorRegistry.controller(for: field.id).bbcodeSession.insertMarkup(attachment.markup)
        synchronizeLocalDraft()
    }

    func removeAsset(_ id: UUID, form: ForumForm) async {
        guard uploadingAssetID != id, let asset = composerAssets.first(where: { $0.id == id }) else { return }
        if let anchor = assetAnchors[id], let field = form.fields.first(where: { $0.name == "message" }) { editorRegistry?.controller(for: field.id).bbcodeSession.removeBookmark(anchor) }
        composerAssets.removeAll { $0.id == id }; assetFiles[id] = nil; assetAnchors[id] = nil; assetFailures[id] = nil
        if let uploadID = asset.uploadID { attachments[form.id]?.removeAll { $0.id == uploadID } }
        if let fieldName = asset.fieldName { selectedFiles[form.id]?.removeAll { $0.fieldName == fieldName } }
        synchronizeLocalDraft()
        await composerDraft?.cleanResources()
    }

    func stageFormFile(_ file: ForumFormFile, form: ForumForm) async {
        guard page?.forms.contains(form) == true else { return }
        let draftID = composerDraft?.current?.id
        let generation = pageGeneration
        do { try await checkGeneration(generation) } catch { return }
        guard composerDraft?.current?.id == draftID, page?.forms.contains(form) == true else { return }
        var files = selectedFiles[form.id] ?? []
        files.removeAll { $0.fieldName == file.fieldName }; files.append(file)
        selectedFiles[form.id] = files
        guard form.kind == .thread else { return }
        var asset = ForumComposerDraftAttachment(name: file.file.name, mimeType: file.mimeType, isImage: false, fieldName: file.fieldName)
        assetFiles[asset.id] = file.file
        do { if let composerDraft, composerDraft.active { asset.resourceID = try await composerDraft.importResource(file.file) } }
        catch {
            do { try await checkGeneration(generation) } catch { return }
            guard composerDraft?.current?.id == draftID else { return }
            assetFailures[asset.id] = error.localizedDescription
        }
        guard composerDraft?.current?.id == draftID else { return }
        guard selectedFiles[form.id]?.contains(file) == true else {
            assetFiles[asset.id] = nil; assetFailures[asset.id] = nil
            await composerDraft?.cleanResources()
            return
        }
        let replaced = composerAssets.filter { $0.fieldName == file.fieldName }
        for old in replaced { assetFiles[old.id] = nil; assetFailures[old.id] = nil }
        composerAssets.removeAll { $0.fieldName == file.fieldName }; composerAssets.append(asset)
        synchronizeLocalDraft()
    }

    func setSelectedFiles(_ files: [ForumFormFile], form: ForumForm) {
        selectedFiles[form.id] = files
        let names = Set(files.map(\.fieldName))
        let removed = composerAssets.filter { $0.fieldName.map { !names.contains($0) } == true }
        for asset in removed { assetFiles[asset.id] = nil; assetFailures[asset.id] = nil }
        composerAssets.removeAll { $0.fieldName.map { !names.contains($0) } == true }
        synchronizeLocalDraft()
    }

    func composerContext(for form: ForumForm) -> ForumComposerContext {
        var context = page?.composerContext ?? .init()
        for attachment in attachments[form.id] ?? [] where !context.attachments.contains(where: { $0.id == attachment.id }) {
            context.attachments.append(.init(id: attachment.id, name: attachment.name, isImage: attachment.markup.hasPrefix("[attachimg]")))
        }
        return context
    }

    private func checkGeneration(_ generation: UUID?) async throws {
        guard let sessionStore, let generation else { return }
        guard await sessionStore.isCurrentGeneration(generation) else { throw CancellationError() }
    }

    func reportFileError(_ error: Error) { setError(error) }

    func clearError() {
        errorMessage = nil
        errorDetails = nil
        transientFeedback = nil
    }

    private func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
        if page != nil { transientFeedback = .failure(error.localizedDescription, details: errorDetails) }
    }

    static func htmlFromPlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
