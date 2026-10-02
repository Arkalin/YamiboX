import SwiftUI
import YamiboXCore

struct ForumBlacklistManagementView: View {
    let workflow: ForumBlacklistWorkflow
    @State private var errorMessage: String?
    @State private var errorDetails: LoadFailureDetails?

    var body: some View {
        Form {
            Section {
                Picker(L10n.string("blacklist.reply_display"), selection: displayBinding) {
                    Text(L10n.string("blacklist.display_placeholder")).tag(ForumBlockedReplyDisplay.placeholder)
                    Text(L10n.string("blacklist.display_hidden")).tag(ForumBlockedReplyDisplay.hidden)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(L10n.string("blacklist.reply_display"))
            }

            Section {
                if workflow.isRefreshing && workflow.entries.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if !workflow.isLoggedIn {
                    ContentUnavailableView(L10n.string("blacklist.login_required"), systemImage: "person.crop.circle")
                } else if workflow.entries.isEmpty {
                    if let errorMessage {
                        LoadFailureView(message: errorMessage, details: errorDetails) {
                            Task { await refresh() }
                        }
                    } else {
                        ContentUnavailableView(L10n.string("blacklist.empty"), systemImage: "person.slash")
                    }
                } else {
                    ForEach(workflow.entries) { entry in
                        ForumBlacklistManagementRow(entry: entry, isWorking: workflow.isWorking) {
                            Task { await unblock(entry) }
                        }
                    }
                }
            } header: {
                Text(L10n.string("blacklist.title"))
            }
        }
        .navigationTitle(L10n.string("blacklist.management"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.string("common.refresh"))
                .disabled(workflow.isRefreshing || workflow.isWorking)
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .failureAlert(
            L10n.string("common.operation_failed"), message: errorMessage, details: errorDetails,
            isPresented: Binding(
                get: { errorMessage != nil && !workflow.entries.isEmpty },
                set: { if !$0 { errorMessage = nil; errorDetails = nil } }
            )
        ) {
            Button(L10n.string("common.ok")) { errorMessage = nil; errorDetails = nil }
        }
        .onChange(of: workflow.accountUID) { _, _ in
            errorMessage = nil
            errorDetails = nil
        }
    }

    private var displayBinding: Binding<ForumBlockedReplyDisplay> {
        Binding(get: { workflow.replyDisplay }, set: { display in
            Task {
                do { try await workflow.setReplyDisplay(display) }
                catch { showError(error) }
            }
        })
    }

    private func refresh() async {
        errorMessage = nil
        errorDetails = nil
        do { try await workflow.refresh() }
        catch { showError(error) }
    }

    private func unblock(_ entry: ForumBlacklistEntry) async {
        do { try await workflow.setBlocked(false, uid: entry.uid) }
        catch { showError(error) }
    }

    private func showError(_ error: any Error) {
        guard !LoadDiagnosticError.isCancellation(error) else { return }
        if LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated {
            errorMessage = L10n.string("blacklist.login_required")
        } else {
            errorMessage = error.localizedDescription
        }
        errorDetails = LoadFailureDetails(error: error)
    }
}

private struct ForumBlacklistManagementRow: View {
    let entry: ForumBlacklistEntry
    let isWorking: Bool
    let unblock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForumAvatarView(url: entry.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.username)
                Text("UID: \(entry.uid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.string("blacklist.unblock"), action: unblock)
                .font(.subheadline)
                .buttonStyle(.borderless)
                .disabled(isWorking)
                .accessibilityLabel(L10n.string("blacklist.unblock_user", entry.username))
        }
        .padding(.vertical, 4)
    }
}
