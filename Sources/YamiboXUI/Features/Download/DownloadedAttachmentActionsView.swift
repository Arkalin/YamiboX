import QuickLook
import SwiftUI
import YamiboXCore

struct DownloadedAttachmentActionsView: View {
    let entryID: DownloadEntryID
    let viewModel: DownloadManagementViewModel
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        HStack {
            if let localURL {
                Button { previewURL = localURL } label: {
                    Label(L10n.string("forum.native.preview_file"), systemImage: "eye")
                }
                Spacer()
                ShareLink(item: localURL) {
                    Label(L10n.string("common.share"), systemImage: "square.and.arrow.up")
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .buttonStyle(.borderless)
        .quickLookPreview($previewURL)
        .task(id: entryID) {
            do { localURL = try await viewModel.attachmentURL(id: entryID) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
