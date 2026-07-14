import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class UserSpaceAddFriendSheetModel {
    static let noteMaxLength = 10

    var note = "" {
        didSet {
            if note.count > Self.noteMaxLength {
                note = String(note.prefix(Self.noteMaxLength))
            }
        }
    }

    var selectedGroupID: Int?

    func resolvedGroupID(for form: UserSpaceAddFriendForm) -> Int {
        selectedGroupID ?? form.options.first?.id ?? 1
    }

    func resetGroupSelection(for form: UserSpaceAddFriendForm?) {
        selectedGroupID = form?.options.first?.id
    }
}

struct UserSpaceAddFriendSheet: View {
    let targetName: String?
    let form: UserSpaceAddFriendForm?
    let isLoading: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let retry: () -> Void
    let submit: (String, Int) -> Void
    let dismiss: () -> Void

    @State private var model = UserSpaceAddFriendSheetModel()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    UserSpaceAddFriendLoadingView()
                } else if let errorMessage {
                    UserSpaceErrorView(message: errorMessage, retry: retry)
                } else if let form {
                    UserSpaceAddFriendFormView(
                        targetName: form.name ?? targetName,
                        avatarURL: form.avatarURL,
                        options: form.options,
                        note: $model.note,
                        selectedGroupID: Binding(
                            get: { model.resolvedGroupID(for: form) },
                            set: { model.selectedGroupID = $0 }
                        ),
                        isSubmitting: isSubmitting,
                        submit: {
                            submit(model.note, model.resolvedGroupID(for: form))
                        }
                    )
                } else {
                    UserSpaceEmptyView(message: L10n.string("user_space.add_friend_form_unavailable"))
                }
            }
            .navigationTitle(L10n.string("user_space.add_friend"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: dismiss)
                        .disabled(isSubmitting)
                }
            }
            .task(id: form?.formHash) {
                model.resetGroupSelection(for: form)
            }
        }
    }
}

private struct UserSpaceAddFriendFormView: View {
    let targetName: String?
    let avatarURL: URL?
    let options: [UserSpaceAddFriendOption]
    @Binding var note: String
    @Binding var selectedGroupID: Int
    let isSubmitting: Bool
    let submit: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForumAvatarView(url: avatarURL, size: 52, placeholderFont: .largeTitle)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(targetName ?? L10n.string("user_space.unknown_user"))
                            .font(.headline)
                        Text(L10n.string("user_space.add_friend_note_limit"))
                            .font(.caption)
                            .foregroundStyle(ForumColors.secondaryText)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(L10n.string("user_space.add_friend_note")) {
                TextField(L10n.string("user_space.add_friend_note_placeholder"), text: $note)
                    .disabled(isSubmitting)
            }

            Section(L10n.string("user_space.add_friend_group")) {
                Picker(L10n.string("user_space.add_friend_group"), selection: $selectedGroupID) {
                    ForEach(options) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(isSubmitting)
            }

            Section {
                FormSubmitButton(
                    title: L10n.string("user_space.add_friend_submit"),
                    isLoading: isSubmitting,
                    action: submit
                )
                .disabled(isSubmitting)
            }
        }
    }
}

private struct UserSpaceAddFriendLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("user_space.add_friend_loading"))
                .font(.subheadline)
                .foregroundStyle(ForumColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
