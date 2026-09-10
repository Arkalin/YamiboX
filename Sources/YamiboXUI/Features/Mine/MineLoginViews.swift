import SwiftUI
import YamiboXCore

struct MineLoginSheet: View {
    let viewModel: MineHomeViewModel
    let sessionStore: SessionStore
    let appModel: YamiboAppModel
    let close: () -> Void

    var body: some View {
        AccountLoginSheet(switcher: appModel.appContext.accountSwitcher) {
            Task {
                await viewModel.reloadAccountSnapshot()
                close()
            }
        } onCancel: {
            close()
        }
    }
}

@MainActor
final class MineWebLoginSessionMonitor {
    private let sessionStore: SessionStore
    private let changes: AsyncStream<String>
    private var baselineAuthenticationValue: String?

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        changes = sessionStore.changes()
    }

    func waitForAuthentication() async -> Bool {
        baselineAuthenticationValue = await authenticationValue()
        // A session that is already authenticated needs no change event; this
        // also avoids missing a login that landed before the baseline read.
        if await isAuthenticatedNow() {
            return true
        }

        for await changeID in changes {
            guard !Task.isCancelled else { return false }
            guard changeID == sessionStore.changeID else { continue }
            if await isAuthenticatedAfterMonitoringStarted() {
                return true
            }
        }

        return false
    }

    private func authenticationValue() async -> String? {
        let session = await sessionStore.load()
        return session.authenticationCookie?.value
    }

    private func isAuthenticatedAfterMonitoringStarted() async -> Bool {
        let session = await sessionStore.load()
        guard session.isLoggedIn, let value = session.authenticationCookie?.value else { return false }
        return baselineAuthenticationValue == nil || value != baselineAuthenticationValue
    }

    private func isAuthenticatedNow() async -> Bool {
        let session = await sessionStore.load()
        return session.isLoggedIn && session.authenticationCookie != nil
    }
}

struct AccountLoginForm: View {
    let viewModel: AccountLoginViewModel
    let onWebLogin: () -> Void
    let onLoginSuccess: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var selectedQuestionID = YamiboLoginQuestion.none.id
    @State private var answer = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            TextField(L10n.string("mine.login_username"), text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            SecureField(L10n.string("mine.login_password"), text: $password)
                .textContentType(.password)

            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    questionPicker
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("mine.security_question")).foregroundStyle(.primary)
                        Text(viewModel.loginQuestions.first { $0.id == selectedQuestionID }?.title ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                questionPicker
            }

            if selectedQuestionID != YamiboLoginQuestion.none.id {
                TextField(L10n.string("mine.security_answer"), text: $answer)
                    .autocorrectionDisabled()
            }
        }
        .task { username = viewModel.initialUsername }

        MineWebLoginLinkRow(action: onWebLogin)

        Section {
            FormSubmitButton(
                title: L10n.string("mine.login"),
                isLoading: viewModel.isLoggingIn
            ) {
                Task {
                    let didLogin = await viewModel.login(
                        username: username,
                        password: password,
                        questionID: selectedQuestionID,
                        answer: answer
                    )
                    if didLogin {
                        password = ""
                        answer = ""
                        onLoginSuccess()
                    }
                }
            }
            .disabled(loginIsDisabled)
        }
    }

    private var loginIsDisabled: Bool {
        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.isEmpty
            || viewModel.isLoggingIn
    }

    private var questionPicker: some View {
        Picker(L10n.string("mine.security_question"), selection: $selectedQuestionID) {
            ForEach(viewModel.loginQuestions) { question in
                Text(question.title).tag(question.id)
            }
        }
    }
}

private struct MineWebLoginLinkRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(L10n.string("mine.web_login"))
                .font(.footnote)
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}
