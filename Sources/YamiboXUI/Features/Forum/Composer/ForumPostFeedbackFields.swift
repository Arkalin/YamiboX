import SwiftUI
import YamiboXCore

struct ForumPostRatingForm: View {
    @Bindable var model: ForumThreadRateSheetModel
    let disabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ForumComposerStyle.fieldSpacing) {
                HStack {
                    Text(L10n.string("forum.thread.rate_score"))
                    Spacer()
                    TextField(L10n.string("forum.thread.rate_score"), text: $model.scoreText)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 60, maxWidth: 100, minHeight: ForumComposerStyle.controlSize)
                        .accessibilityIdentifier("chapter-comment-score")
                    if let scores = model.options?.availableScores, !scores.isEmpty {
                        Menu {
                            ForEach(scores, id: \.self) { score in
                                Button(String(score)) { model.scoreText = String(score) }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down").frame(minWidth: ForumComposerStyle.controlSize, minHeight: ForumComposerStyle.controlSize)
                        }
                        .accessibilityLabel(L10n.string("forum.thread.rate_score_options"))
                    }
                }
                Divider()
                TextField(L10n.string("forum.thread.rate_reason"), text: $model.reason, axis: .vertical)
                    .lineLimit(4 ... 8)
                    .accessibilityIdentifier("chapter-comment-reason")
                if let reasons = model.options?.defaultReasons, !reasons.isEmpty {
                    Menu {
                        ForEach(reasons, id: \.self) { reason in
                            Button(reason) { model.reason = reason }
                        }
                    } label: {
                        Label(L10n.string("forum.thread.rate_reason_options"), systemImage: "text.badge.plus")
                            .frame(minHeight: ForumComposerStyle.controlSize)
                    }
                }
                Divider()
                Toggle(L10n.string("forum.thread.rate_notice_author"), isOn: $model.noticeAuthor)
            }
            .padding(ForumComposerStyle.contentInset)
            .disabled(disabled || model.isLoadingOptions)
            if model.isLoadingOptions { ProgressView().padding() }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

struct ForumPostCommentFields: View {
    @Bindable var model: ForumThreadCommentSheetModel
    let disabled: Bool

    var body: some View {
        TextEditor(text: $model.message)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if model.message.isEmpty {
                    Text(L10n.string("forum.thread.comment_placeholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .disabled(disabled)
            .accessibilityLabel(L10n.string("forum.thread.comment"))
            .accessibilityIdentifier("chapter-comment-text")
            .failureToast(message: model.errorMessage, details: model.errorDetails,
                          eventID: model.errorEventID, clear: model.clearError)
    }
}
