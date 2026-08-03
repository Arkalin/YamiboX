import SwiftUI
import YamiboXCore

struct MineLoginSheet: View {
    let viewModel: MineHomeViewModel
    let sessionStore: SessionStore
    let appModel: YamiboAppModel
    let close: () -> Void

    @State private var isWebLoginPresented = false

    var body: some View {
        NavigationStack {
            List {
                MineLoginSection(
                    viewModel: viewModel,
                    onWebLogin: { isWebLoginPresented = true },
                    onLoginSuccess: close
                )
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .navigationTitle(L10n.string("mine.login"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: close)
                }
            }
            .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
                Button(L10n.string("common.ok")) {
                    viewModel.errorMessage = nil
                }
            }, message: {
                Text(viewModel.errorMessage ?? "")
            })
        }
        .sheet(isPresented: $isWebLoginPresented, onDismiss: refreshAfterWebLogin) {
            MineWebLoginSheet(
                sessionStore: sessionStore,
                appModel: appModel,
                close: { isWebLoginPresented = false }
            )
        }
        .task(id: isWebLoginPresented) {
            guard isWebLoginPresented else { return }

            let monitor = MineWebLoginSessionMonitor(sessionStore: sessionStore)
            guard await monitor.waitForAuthentication(), !Task.isCancelled else { return }
            isWebLoginPresented = false
        }
    }

    private func refreshAfterWebLogin() {
        Task {
            viewModel.session = await sessionStore.load()
            if viewModel.isLoggedIn {
                close()
            }
            await viewModel.load()
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                }
            }
        )
    }
}

@MainActor
final class MineWebLoginSessionMonitor {
    private let sessionStore: SessionStore
    private let changes: AsyncStream<String>

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        changes = sessionStore.changes()
    }

    func waitForAuthentication() async -> Bool {
        if await isAuthenticated() {
            return true
        }

        for await changeID in changes {
            guard !Task.isCancelled else { return false }
            guard changeID == sessionStore.changeID else { continue }
            if await isAuthenticated() {
                return true
            }
        }

        return false
    }

    private func isAuthenticated() async -> Bool {
        let session = await sessionStore.load()
        return session.isLoggedIn && SessionState.hasAuthenticationCookie(session.cookie)
    }
}

private struct MineLoginSection: View {
    let viewModel: MineHomeViewModel
    let onWebLogin: () -> Void
    let onLoginSuccess: () -> Void

    @AppStorage("yamibox.login.username") private var username = ""
    @State private var password = ""
    @State private var selectedQuestionID = YamiboLoginQuestion.none.id
    @State private var answer = ""

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

            Picker(L10n.string("mine.security_question"), selection: $selectedQuestionID) {
                ForEach(viewModel.loginQuestions) { question in
                    Text(question.title).tag(question.id)
                }
            }

            if selectedQuestionID != YamiboLoginQuestion.none.id {
                TextField(L10n.string("mine.security_answer"), text: $answer)
                    .autocorrectionDisabled()
            }
        }

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

private struct MineWebLoginSheet: View {
    let sessionStore: SessionStore
    let appModel: YamiboAppModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ForumBrowserView(
                url: YamiboRoute.login.url,
                sessionStore: sessionStore,
                appModel: appModel,
                listensToForumNavigationRequest: false
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close"), action: close)
                }
            }
        }
    }
}
