import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class ForumThreadCommentSheetModel {
    var message = ""
    private(set) var isSubmitting = false
    private(set) var successMessage: String?
    private(set) var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?
    private(set) var errorEventID = UUID()

    @ObservationIgnored private let postID: String
    @ObservationIgnored private let submit: (String, String) async throws -> String

    init(postID: String, submit: @escaping (String, String) async throws -> String) {
        self.postID = postID
        self.submit = submit
    }

    var canSubmit: Bool {
        !isSubmitting && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearError() { errorMessage = nil }

    /// Returns true when the comment was submitted and the sheet should dismiss.
    func submitComment() async -> Bool {
        guard canSubmit else { return false }
        errorEventID = UUID()
        isSubmitting = true
        successMessage = nil
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            successMessage = try await submit(postID, message)
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

struct ForumThreadCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForumThreadCommentSheetModel
    @State private var submissionTask: Task<Void, Never>?

    init(postID: String, submit: @escaping (String, String) async throws -> String) {
        _model = State(wrappedValue: ForumThreadCommentSheetModel(postID: postID, submit: submit))
    }

    var body: some View {
        NavigationStack {
            ForumPostCommentFields(model: model, disabled: model.isSubmitting)
                .modifier(ForumComposerSurface())
                .navigationTitle(L10n.string("forum.thread.comment"))
                .toolbar {
                    ForumComposerToolbar(isBusy: model.isSubmitting, isSubmitting: model.isSubmitting,
                                         canSubmit: model.canSubmit, close: { dismiss() }) {
                        submissionTask = Task {
                            if await model.submitComment() { dismiss() }
                        }
                    }
                }
        }
        .modifier(ForumComposerSheetPresentation())
        .interactiveDismissDisabled(model.isSubmitting)
        .onDisappear { submissionTask?.cancel() }
    }
}
