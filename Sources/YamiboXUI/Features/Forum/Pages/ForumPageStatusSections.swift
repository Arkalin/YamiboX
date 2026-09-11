import SwiftUI
import YamiboXCore

struct ForumPageStatusSections: View {
    let document: ForumPageDocument
    let onURLTap: (URL) -> Void

    var body: some View {
        if !document.composerLinks.isEmpty {
            Section {
                ForEach(document.composerLinks, id: \.url) { link in
                    Button(link.title) { onURLTap(link.url) }
                }
            }
        }
        if let message = document.message {
            Section { Text(message) }
        }
        if let file = document.file {
            Section { ForumAttachmentFileView(file: file) }
        }
        if let url = document.continuationURL,
           !ForumWebPagePolicy.requiresConfirmationToLoad(url) {
            Section {
                Button { onURLTap(url) } label: {
                    Label(L10n.string("forum.native.continue"), systemImage: "arrow.right")
                }
            }
        }
    }
}
