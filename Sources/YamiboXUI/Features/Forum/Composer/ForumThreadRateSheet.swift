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
            ForumPostRatingFields(model: model, disabled: model.isSubmitting)
                .modifier(ForumComposerSurface())
                .navigationTitle(L10n.string("forum.thread.ratings"))
                .toolbar {
                    ForumComposerToolbar(isBusy: model.isSubmitting, isSubmitting: model.isSubmitting,
                                         canSubmit: model.canSubmit, close: { dismiss() }) {
                        submissionTask = Task {
                            if await model.submitRate() { dismiss() }
                        }
                    }
                }
        }
        .modifier(ForumComposerSheetPresentation())
        .interactiveDismissDisabled(model.isSubmitting)
        .task { await model.loadRateOptions() }
        .onDisappear { submissionTask?.cancel() }
    }
}
