import SwiftUI
import YamiboXCore

enum WebDAVSyncSettingsAction: Equatable {
    case loading
    case syncing
}

@MainActor
final class WebDAVSyncSettingsViewModel: ObservableObject {
    @Published var baseURLString = ""
    @Published var username = ""
    @Published var password = ""
    @Published var isAutoSyncEnabled = true
    @Published var direction: WebDAVSyncDirection = .upload
    @Published private(set) var activeAction: WebDAVSyncSettingsAction?
    @Published private(set) var lastSyncedAt: Date?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var isShowingAccountMismatchConfirmation = false

    private let dependencies: WebDAVSyncDependencies

    init(dependencies: WebDAVSyncDependencies) {
        self.dependencies = dependencies
    }

    var isBusy: Bool {
        activeAction != nil
    }

    var canContinue: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isBusy
    }

    func load() async {
        activeAction = .loading
        defer { activeAction = nil }

        let settings = await dependencies.settingsStore.load()
        baseURLString = settings.baseURLString
        username = settings.username
        password = settings.password
        isAutoSyncEnabled = settings.isAutoSyncEnabled
        lastSyncedAt = settings.lastSyncedAt
    }

    func continueSync(allowingAccountMismatch: Bool = false) async -> Bool {
        activeAction = .syncing
        defer { activeAction = nil }

        var settings = await dependencies.settingsStore.load()
        settings.baseURLString = baseURLString
        settings.username = username
        settings.password = password
        settings.isAutoSyncEnabled = isAutoSyncEnabled
        settings.baseURLString = settings.trimmedBaseURLString
        settings.username = settings.trimmedUsername

        guard settings.isConfigured else {
            errorMessage = L10n.string("webdav.error.invalid_configuration")
            return false
        }

        do {
            try await dependencies.settingsStore.save(settings)
            let service = dependencies.makeSyncService()
            switch direction {
            case .upload:
                _ = try await service.upload(using: settings, allowingAccountMismatch: allowingAccountMismatch)
            case .download:
                _ = try await service.download(using: settings, allowingAccountMismatch: allowingAccountMismatch)
            }
            let updatedSettings = await dependencies.settingsStore.load()
            lastSyncedAt = updatedSettings.lastSyncedAt
            successMessage = L10n.string("webdav.sync_success")
            return true
        } catch WebDAVSyncError.accountMismatch {
            if direction == .upload {
                isShowingAccountMismatchConfirmation = true
            } else {
                errorMessage = L10n.string("webdav.error.account_mismatch")
            }
            return false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}

public struct WebDAVSyncSettingsView: View {
    @StateObject private var viewModel: WebDAVSyncSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    public init(dependencies: WebDAVSyncDependencies) {
        _viewModel = StateObject(wrappedValue: WebDAVSyncSettingsViewModel(dependencies: dependencies))
    }

    /// Hierarchy detail of the storage settings page: pushed onto the
    /// settings navigation stack rather than presented as a sheet, so back
    /// navigation matches its sibling rows (e.g. offline cache management).
    public var body: some View {
        Form {
                Section {
                    labeledTextField(
                        title: L10n.string("webdav.url"),
                        text: $viewModel.baseURLString
                    )
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif

                    labeledTextField(
                        title: L10n.string("webdav.username"),
                        text: $viewModel.username
                    )
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("webdav.password"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("", text: $viewModel.password)
                            .textContentType(.password)
                            .disabled(viewModel.isBusy)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle(isOn: $viewModel.isAutoSyncEnabled) {
                        Label(L10n.string("webdav.auto_sync"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isBusy)

                    Picker(L10n.string("webdav.operation"), selection: $viewModel.direction) {
                        Text(title(for: .upload)).tag(WebDAVSyncDirection.upload)
                        Text(title(for: .download)).tag(WebDAVSyncDirection.download)
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isBusy)
                    .padding(.vertical, 4)
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .font(.title3)
                        Text(L10n.string("webdav.sync_note"))
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.blue.opacity(0.82))
                }

                Section {
                    Button {
                        Task {
                            let didSync = await viewModel.continueSync()
                            if didSync {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.activeAction == .syncing {
                                ProgressView()
                            } else {
                                Text(L10n.string("webdav.continue"))
                            }
                            Spacer()
                        }
                    }
                    .disabled(!viewModel.canContinue)

                    if let lastSyncedAt = viewModel.lastSyncedAt {
                        Text(L10n.string("webdav.last_synced", lastSyncedAt.formatted(date: .abbreviated, time: .standard)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.string("webdav.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .overlay {
                if viewModel.activeAction == .loading {
                    ProgressView(L10n.string("common.loading"))
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task {
                await viewModel.load()
            }
            .alert(
                L10n.string("common.operation_failed"),
                isPresented: .presentation(
                    isPresented: { viewModel.errorMessage != nil },
                    clearOnDismiss: { viewModel.errorMessage = nil }
                ),
                actions: {
                    Button(L10n.string("common.ok")) {}
                },
                message: {
                    Text(viewModel.errorMessage ?? "")
                }
            )
            .alert(L10n.string("webdav.account_mismatch_title"), isPresented: .presentation(
                isPresented: { viewModel.isShowingAccountMismatchConfirmation },
                clearOnDismiss: { viewModel.isShowingAccountMismatchConfirmation = false }
            ), actions: {
                Button(L10n.string("webdav.account_mismatch_overwrite"), role: .destructive) {
                    Task {
                        let didSync = await viewModel.continueSync(allowingAccountMismatch: true)
                        if didSync {
                            dismiss()
                        }
                    }
                }
                Button(L10n.string("common.cancel"), role: .cancel) {}
            }, message: {
                Text(L10n.string("webdav.account_mismatch_message"))
            })
    }

    private func labeledTextField(
        title: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .autocorrectionDisabled()
                .disabled(viewModel.isBusy)
        }
        .padding(.vertical, 4)
    }

    private func title(for direction: WebDAVSyncDirection) -> String {
        switch direction {
        case .upload:
            L10n.string("webdav.upload")
        case .download:
            L10n.string("webdav.download")
        }
    }
}
