import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class ForumThreadRateSheetModel {
    var scoreText = ""
    var reason = ""
    var noticeAuthor = false
    private(set) var options: ForumThreadRateOptionsPage?
    private(set) var optionsFailure: TransientFeedback?
    private(set) var canRetryOptions = true
    private(set) var isLoadingOptions = false
    private(set) var isSubmitting = false
    private(set) var successMessage: String?
    private(set) var hintMessage: String?
    private(set) var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?
    private(set) var errorEventID = UUID()

    @ObservationIgnored private let postID: String
    @ObservationIgnored private let loadOptions: (String) async throws -> ForumThreadRateOptionsPage
    @ObservationIgnored private let submit: (String, Int, String, Bool) async throws -> String

    init(
        postID: String,
        loadOptions: @escaping (String) async throws -> ForumThreadRateOptionsPage,
        submit: @escaping (String, Int, String, Bool) async throws -> String
    ) {
        self.postID = postID
        self.loadOptions = loadOptions
        self.submit = submit
    }

    var canSubmit: Bool {
        !isSubmitting && !isLoadingOptions && optionsFailure == nil
            && !scoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadRateOptions() async {
        guard !isLoadingOptions, !isSubmitting else { return }
        isLoadingOptions = true
        options = nil
        optionsFailure = nil
        canRetryOptions = true
        errorMessage = nil
        hintMessage = L10n.string("forum.thread.rate_loading_options")
        defer { isLoadingOptions = false }

        do {
            options = try await loadOptions(postID)
            hintMessage = nil
        } catch {
            hintMessage = nil
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
                optionsFailure = .failure(error)
                if case .underlying = LoadDiagnosticError.classificationError(error) as? YamiboError {
                    canRetryOptions = false
                }
                errorEventID = UUID()
            }
        }
    }

    func clearError() { errorMessage = nil }

    /// Returns true when the rating was submitted and the sheet should dismiss.
    func submitRate() async -> Bool {
        guard !isSubmitting, !isLoadingOptions, optionsFailure == nil else { return false }
        errorEventID = UUID()
        guard let score = Int(scoreText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = L10n.string("forum.thread.rate_score_invalid")
            return false
        }
        isSubmitting = true
        successMessage = nil
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            successMessage = try await submit(postID, score, reason, noticeAuthor)
            return !Task.isCancelled
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }
}

struct ForumThreadRateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForumThreadRateSheetModel
    @State private var submissionTask: Task<Void, Never>?

    init(
        postID: String,
        loadOptions: @escaping (String) async throws -> ForumThreadRateOptionsPage,
        submit: @escaping (String, Int, String, Bool) async throws -> String
    ) {
        _model = State(wrappedValue: ForumThreadRateSheetModel(postID: postID, loadOptions: loadOptions, submit: submit))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let failure = model.optionsFailure {
                    LoadFailureView(title: L10n.string("forum.thread.rate_unavailable"), systemImage: "star.slash",
                                    message: failure.message, details: failure.details, showsRetry: model.canRetryOptions) {
                        Task { await model.loadRateOptions() }
                    }
                } else {
                    ForumThreadRateForm(model: model)
                }
            }
            .navigationTitle(L10n.string("forum.thread.ratings"))
            .failureToast(message: model.optionsFailure == nil ? model.errorMessage : nil, details: model.errorDetails,
                          eventID: model.errorEventID, clear: model.clearError)
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSubmitting ? L10n.string("forum.thread.submitting") : L10n.string("forum.thread.submit")) {
                        submissionTask = Task {
                            if await model.submitRate() {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSubmit)
                }
            }
            .overlay {
                if model.isLoadingOptions || model.isSubmitting {
                    ProgressView()
                }
            }
        }
        .task {
            await model.loadRateOptions()
        }
        .onDisappear { submissionTask?.cancel() }
    }
}

private struct ForumThreadRateForm: View {
    @Environment(\.forumTheme) private var theme
    @Bindable var model: ForumThreadRateSheetModel

    var body: some View {
        Form {
            Section {
                TextField(L10n.string("forum.thread.rate_score"), text: $model.scoreText)

                if let options = model.options, !options.availableScores.isEmpty {
                    Menu(L10n.string("forum.thread.rate_score_options")) {
                        ForEach(options.availableScores, id: \.self) { score in
                            Button(String(score)) {
                                model.scoreText = String(score)
                            }
                        }
                    }
                }

                TextField(L10n.string("forum.thread.rate_reason"), text: $model.reason, axis: .vertical)
                    .lineLimit(3 ... 5)

                if let options = model.options, !options.defaultReasons.isEmpty {
                    Menu(L10n.string("forum.thread.rate_reason_options")) {
                        ForEach(options.defaultReasons, id: \.self) { value in
                            Button(value) {
                                model.reason = value
                            }
                        }
                    }
                }

                Toggle(L10n.string("forum.thread.rate_notice_author"), isOn: $model.noticeAuthor)
            }

            if let hintMessage = model.hintMessage {
                Section {
                    Text(hintMessage)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }
}
