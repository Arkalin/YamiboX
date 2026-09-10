import SwiftUI
import YamiboXCore

struct ForumDocumentView: View {
    let document: ForumPageDocument
    let onRefresh: () async -> Void
    let onURLTap: (URL) -> Void
    @State private var imageRequest: ForumThreadImageBrowserRequest?

    var body: some View {
        List {
            ForumDocumentSections(document: document, onImageTap: showImage, onURLTap: onURLTap)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await onRefresh() }
        .accessibilityIdentifier("forum-document")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await onRefresh() } } label: {
                        Label(L10n.string("common.refresh"), systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L10n.string("forum.native.more_actions"))
            }
        }
        .fullScreenCover(item: $imageRequest) { request in
            ImageBrowserView(items: request.items, initialItemID: request.initialItemID, mode: .single) { imageRequest = nil }
        }
    }

    private func showImage(_ id: String, _ url: URL, _ title: String?, _ referer: URL) {
        imageRequest = ForumThreadImageBrowserRequest(
            items: [ImageBrowserItem(id: id, source: YamiboImageSource(url: url, refererPageURL: referer), title: title ?? document.title)],
            initialItemID: id
        )
    }
}

struct ForumDocumentSections: View {
    let document: ForumPageDocument
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        if let file = document.file {
            Section { ForumAttachmentFileView(file: file) }
        }
        if let url = document.continuationURL {
            Section {
                Button { onURLTap(url) } label: {
                    Label(L10n.string("forum.native.continue"), systemImage: "arrow.right")
                }
            }
        }
        if !document.blocks.isEmpty {
            Section {
                ForumThreadContentBlocksView(blocks: document.blocks, fallbackText: "", refererURL: document.url,
                                             onImageTap: onImageTap, onURLTap: onURLTap)
                    .listRowBackground(Color.clear)
            }
        }
    }
}
