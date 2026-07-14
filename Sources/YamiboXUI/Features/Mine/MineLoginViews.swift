import SwiftUI
import YamiboXCore

struct MineLoginSheet: View {
    let viewModel: MineHomeViewModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                MineLoginSection(viewModel: viewModel, onLoginSuccess: close)
            }
            .listStyle(.insetGrouped)
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

private struct MineLoginSection: View {
    let viewModel: MineHomeViewModel
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
