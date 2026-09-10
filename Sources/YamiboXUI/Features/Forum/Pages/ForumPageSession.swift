import Foundation
import Observation
import YamiboXCore

protocol ForumPageLoading: Sendable {
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageDocument
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageDocument
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment
}

extension ForumPageRepository: ForumPageLoading {}

@MainActor
@Observable
final class ForumPageSession {
    let url: URL
    private(set) var page: ForumPageDocument?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var errorDetails: LoadFailureDetails?
    var errorMessage: String?
    var transientFeedback: TransientFeedback?
    var drafts: [String: [String: [String]]] = [:]
    var htmlSourceFields: Set<String> = []
    var pendingSubmission: Submission?
    var showsDiscardConfirmation = false
    var selectedFiles: [String: [ForumFormFile]] = [:]
    private(set) var attachments: [String: [ForumUploadedAttachment]] = [:]
    private(set) var isUploading = false
    private(set) var submissionResponse: ForumPageDocument?
    private(set) var submissionSucceeded = false
    private(set) var requiresLoadConfirmation: Bool

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
    }

    init(url: URL, dependencies: ForumDependencies, onSubmissionAccepted: ((ForumSubmissionChange) -> Void)? = nil) {
        self.url = url
        self.onSubmissionAccepted = onSubmissionAccepted
        requiresLoadConfirmation = ForumWebPagePolicy.requiresConfirmationToLoad(url)
        repositoryProvider = { await dependencies.makePageRepository() }
    }

    init(url: URL, repository: any ForumPageLoading, onSubmissionAccepted: ((ForumSubmissionChange) -> Void)? = nil) {
        self.url = url
        self.onSubmissionAccepted = onSubmissionAccepted
        requiresLoadConfirmation = ForumWebPagePolicy.requiresConfirmationToLoad(url)
        repositoryProvider = { repository }
    }

    var hasEdits: Bool {
        guard let page, !submissionSucceeded else { return false }
        return selectedFiles.values.contains { !$0.isEmpty } || attachments.values.contains { !$0.isEmpty } ||
            page.forms.contains { (drafts[$0.id] ?? $0.initialValues) != $0.initialValues }
    }

    func load(confirmedAction: Bool = false) async {
        guard !isLoading, !isSubmitting, !isUploading, page == nil,
              confirmedAction || !requiresLoadConfirmation else { return }
        isLoading = true
        clearError()
        defer { isLoading = false }
        do {
            let repository = await repositoryProvider()
            let result = try await repository.fetchPage(url: url, confirmedAction: confirmedAction)
            try Task.checkCancellation()
            page = result
            drafts = Dictionary(uniqueKeysWithValues: result.forms.map { ($0.id, $0.initialValues) })
            htmlSourceFields = Set(result.forms.filter { $0.kind == .blog }.flatMap { form in
                form.fields.filter { $0.name == "message" && $0.initialValues.first?.isEmpty == false }.map(\.id)
            })
            requiresLoadConfirmation = false
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) { setError(error) }
        }
    }

    func refresh(discardingEdits: Bool = false) async {
        guard !isLoading, !isSubmitting, !isUploading else { return }
        if hasEdits && !discardingEdits {
            showsDiscardConfirmation = true
            return
        }
        // Confirmation is per request, not a permanent authorization that a
        // refresh can reuse for destructive GET actions.
        requiresLoadConfirmation = ForumWebPagePolicy.requiresConfirmationToLoad(url)
        page = nil
        drafts = [:]
        selectedFiles = [:]
        attachments = [:]
        submissionResponse = nil
        submissionSucceeded = false
        await load()
    }

    func prepareSubmission(form: ForumForm, button: ForumFormButton) {
        guard !isLoading, !isSubmitting, !isUploading, !submissionSucceeded else { return }
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
                                           files: files, attachments: attachments[form.id] ?? [])
            clearError()
        } catch { setError(error) }
    }

    func confirmSubmission(_ submission: Submission? = nil) async {
        // Dialog dismissal can clear presentation state before this task runs.
        // Consume the confirmed snapshot once, independently of that state.
        guard let pending = submission ?? pendingSubmission, let page,
              !isLoading, !isSubmitting, !isUploading, !submissionSucceeded,
              lastConfirmedSubmissionID != pending.id else { return }
        lastConfirmedSubmissionID = pending.id
        pendingSubmission = nil
        isSubmitting = true
        clearError()
        defer { isSubmitting = false }
        do {
            let repository = await repositoryProvider()
            let result = try await repository.submit(
                form: pending.form, values: pending.values, buttonID: pending.buttonID, referer: page.url,
                files: pending.files, attachments: pending.attachments
            )
            if pending.form.method == "GET" || pending.form.actionURL.path == "/search.php" {
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
            submissionSucceeded = result.submissionAccepted
            if submissionSucceeded {
                if let change = ForumSubmissionChange(form: pending.form, sourceURL: page.url, response: result) {
                    onSubmissionAccepted?(change)
                }
                transientFeedback = TransientFeedback(message: message.isEmpty ? L10n.string("forum.native.submitted") : message)
            } else {
                let failure = message.isEmpty ? ForumPageError.submissionUnconfirmed.localizedDescription : message
                errorMessage = failure
                transientFeedback = .failure(failure)
            }
        } catch { setError(error) }
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, form: ForumForm) async {
        guard let page, !isSubmitting, !isUploading,
              let body = form.fields.first(where: { $0.name == "message" }) else { return }
        isUploading = true
        clearError()
        defer { isUploading = false }
        do {
            let repository = await repositoryProvider()
            let result = try await repository.upload(file: file, mimeType: mimeType, configuration: configuration, referer: page.url)
            attachments[form.id, default: []].append(result)
            var values = drafts[form.id] ?? form.initialValues
            var text = values[body.id]?.first ?? ""
            if form.kind == .blog && !htmlSourceFields.contains(body.id) {
                text = Self.htmlFromPlainText(text)
                htmlSourceFields.insert(body.id)
            }
            values[body.id] = [text + "\n" + result.markup]
            drafts[form.id] = values
        } catch { setError(error) }
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
