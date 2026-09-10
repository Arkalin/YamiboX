import QuickLook
import SwiftUI
import YamiboXCore

struct ForumAttachmentFileView: View {
    let file: ForumAttachmentFile
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(file.name, systemImage: "doc")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(Int64(file.data.count), format: .byteCount(style: .file)).foregroundStyle(.secondary)
            if let localURL {
                HStack {
                    Button { previewURL = localURL } label: {
                        Label(L10n.string("forum.native.preview_file"), systemImage: "eye")
                    }
                    Spacer()
                    ShareLink(item: localURL) { Image(systemName: "square.and.arrow.up") }
                }
                .buttonStyle(.borderless)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
        }
        .quickLookPreview($previewURL)
        .task {
            guard localURL == nil else { return }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(file.name)
                do { try file.data.write(to: url, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                localURL = url
            } catch { errorMessage = error.localizedDescription }
        }
        .onDisappear {
            if let localURL { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
            localURL = nil
        }
    }
}
