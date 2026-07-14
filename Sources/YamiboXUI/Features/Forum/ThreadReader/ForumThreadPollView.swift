import SwiftUI
import YamiboXCore

struct ForumThreadPollView: View {
    @State private var selectedOptionIDs: Set<String>
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    let poll: ForumThreadPoll
    let onVote: (([String]) async throws -> String)?
    let onShowVoters: (() -> Void)?

    init(
        poll: ForumThreadPoll,
        onVote: (([String]) async throws -> String)? = nil,
        onShowVoters: (() -> Void)? = nil
    ) {
        self.poll = poll
        self.onVote = onVote
        self.onShowVoters = onShowVoters
        _selectedOptionIDs = State(
            initialValue: Set(poll.options.filter(\.isSelected).map(\.id))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(poll.title, systemImage: "chart.bar.doc.horizontal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ForumColors.brownPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let endTimeText = poll.endTimeText {
                Text(endTimeText)
                    .font(.caption)
                    .foregroundStyle(ForumColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(poll.options) { option in
                    ForumThreadPollOptionView(
                        option: option,
                        pollStatus: poll.status,
                        pollType: poll.type,
                        isSelectedForSubmission: selectedOptionIDs.contains(option.id),
                        showProgress: poll.options.contains { $0.percentage != nil },
                        toggleSelection: {
                            toggle(option.id)
                        }
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(ForumColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if poll.status == .notVoted, let onVote {
                Button {
                    submit(using: onVote)
                } label: {
                    Label(
                        isSubmitting ? L10n.string("forum.thread.poll_submitting") : L10n.string("forum.thread.poll_submit"),
                        systemImage: "paperplane"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(ForumColors.brownPrimary)
                .disabled(selectedOptionIDs.isEmpty || isSubmitting)
            }

            if let onShowVoters {
                Button(action: onShowVoters) {
                    Label(L10n.string("forum.thread.poll_voters"), systemImage: "person.2")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForumColors.brownPrimary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggle(_ optionID: String) {
        errorMessage = nil
        resultMessage = nil
        if poll.type == .multipleChoice {
            if selectedOptionIDs.contains(optionID) {
                selectedOptionIDs.remove(optionID)
            } else {
                selectedOptionIDs.insert(optionID)
            }
        } else {
            selectedOptionIDs = [optionID]
        }
    }

    private func submit(using onVote: @escaping ([String]) async throws -> String) {
        let optionIDs = poll.options
            .map(\.id)
            .filter { selectedOptionIDs.contains($0) }
        guard !optionIDs.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        resultMessage = nil
        Task {
            do {
                resultMessage = try await onVote(optionIDs)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

private struct ForumThreadPollOptionView: View {
    let option: ForumThreadPollOption
    let pollStatus: ForumThreadPollStatus
    let pollType: ForumThreadPollType
    let isSelectedForSubmission: Bool
    let showProgress: Bool
    let toggleSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if pollStatus == .notVoted {
                    toggleSelection()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selectionIconName)
                        .font(.caption)
                        .foregroundStyle(isVisuallySelected ? ForumColors.brownPrimary : ForumColors.secondaryText)
                    Text(option.title)
                        .font(.callout)
                        .foregroundStyle(ForumColors.textDark)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let voteCount = option.voteCount {
                        Text(L10n.string("forum.thread.poll_votes_format", voteCount))
                            .font(.caption)
                            .foregroundStyle(ForumColors.secondaryText)
                    }
                }
                .expandedHitTarget(width: 0)
            }
            .buttonStyle(.plain)
            .disabled(pollStatus != .notVoted)
            .accessibilityAddTraits(isVisuallySelected ? .isSelected : [])

            if showProgress {
                ProgressView(value: min(max((option.percentage ?? 0) / 100, 0), 1))
                    .tint(ForumColors.brownPrimary)
                if let percentage = option.percentage {
                    Text(percentage.formatted(.number.precision(.fractionLength(0 ... 2))) + "%")
                        .font(.caption2)
                        .foregroundStyle(ForumColors.secondaryText)
                }
            }
        }
    }

    private var isVisuallySelected: Bool {
        pollStatus == .notVoted ? isSelectedForSubmission : option.isSelected
    }

    private var selectionIconName: String {
        switch (pollType, isVisuallySelected) {
        case (.multipleChoice, true):
            "checkmark.square.fill"
        case (.multipleChoice, false):
            "square"
        case (_, true):
            "largecircle.fill.circle"
        case (_, false):
            "circle"
        }
    }
}
