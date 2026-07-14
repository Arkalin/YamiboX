import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class ForumThreadRateSheetModel {
    var scoreText = ""
    var reason = ""
    var noticeAuthor = false
    private(set) var options: ForumThreadRateOptionsPage?
    private(set) var isLoadingOptions = false
    private(set) var isSubmitting = false
    private(set) var hintMessage: String?
    private(set) var errorMessage: String?

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
        !isSubmitting && !scoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadRateOptions() async {
        isLoadingOptions = true
        hintMessage = L10n.string("forum.thread.rate_loading_options")
        defer { isLoadingOptions = false }

        do {
            options = try await loadOptions(postID)
            hintMessage = nil
        } catch {
            hintMessage = L10n.string("forum.thread.rate_options_failed")
        }
    }

    /// Returns true when the rating was submitted and the sheet should dismiss.
    func submitRate() async -> Bool {
        guard let score = Int(scoreText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = L10n.string("forum.thread.rate_score_invalid")
            return false
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            _ = try await submit(postID, score, reason, noticeAuthor)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct ForumThreadRateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForumThreadRateSheetModel

    init(
        postID: String,
        loadOptions: @escaping (String) async throws -> ForumThreadRateOptionsPage,
        submit: @escaping (String, Int, String, Bool) async throws -> String
    ) {
        _model = State(wrappedValue: ForumThreadRateSheetModel(postID: postID, loadOptions: loadOptions, submit: submit))
    }

    var body: some View {
        NavigationStack {
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
                            .foregroundStyle(ForumColors.secondaryText)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.string("forum.thread.ratings"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSubmitting ? L10n.string("forum.thread.submitting") : L10n.string("forum.thread.submit")) {
                        Task {
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
    }
}
