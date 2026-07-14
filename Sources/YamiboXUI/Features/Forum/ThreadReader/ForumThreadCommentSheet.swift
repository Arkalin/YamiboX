import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class ForumThreadCommentSheetModel {
    var message = ""
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let postID: String
    @ObservationIgnored private let submit: (String, String) async throws -> String

    init(postID: String, submit: @escaping (String, String) async throws -> String) {
        self.postID = postID
        self.submit = submit
    }

    var canSubmit: Bool {
        !isSubmitting && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns true when the comment was submitted and the sheet should dismiss.
    func submitComment() async -> Bool {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            _ = try await submit(postID, message)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct ForumThreadCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForumThreadCommentSheetModel

    init(postID: String, submit: @escaping (String, String) async throws -> String) {
        _model = State(wrappedValue: ForumThreadCommentSheetModel(postID: postID, submit: submit))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $model.message)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if model.message.isEmpty {
                            Text(L10n.string("forum.thread.comment_placeholder"))
                                .foregroundStyle(ForumColors.secondaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(L10n.string("forum.thread.comment"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSubmitting ? L10n.string("forum.thread.submitting") : L10n.string("forum.thread.publish")) {
                        Task {
                            if await model.submitComment() {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSubmit)
                }
            }
            .overlay {
                if model.isSubmitting {
                    ProgressView()
                }
            }
        }
    }
}
