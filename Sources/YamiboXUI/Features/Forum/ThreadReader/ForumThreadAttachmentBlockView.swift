import SwiftUI
import YamiboXCore

struct ForumThreadFooterAttachmentsView: View {
    let attachments: [ForumThreadAttachmentBlock]
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string("forum.thread.attachments"), systemImage: "paperclip")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ForumColors.brownPrimary)

            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                ForumThreadAttachmentBlockView(block: attachment, onURLTap: onURLTap)
            }
        }
    }
}

struct ForumThreadAttachmentBlockView: View {
    let block: ForumThreadAttachmentBlock
    let onURLTap: (URL) -> Void

    var body: some View {
        Button {
            onURLTap(block.url)
        } label: {
            HStack(spacing: 12) {
                ForumThreadAttachmentIconView(iconURL: block.iconURL)

                VStack(alignment: .leading, spacing: 3) {
                    Text(block.fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForumColors.textDark)
                        .lineLimit(2)
                    if let uploadInfo = block.uploadInfo {
                        Text(uploadInfo)
                            .font(.caption)
                            .foregroundStyle(ForumColors.secondaryText)
                    }
                    if let statInfo = block.statInfo {
                        Text(statInfo)
                            .font(.caption)
                            .foregroundStyle(ForumColors.secondaryText)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ForumColors.brownLight.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ForumThreadAttachmentIconView: View {
    let iconURL: URL?

    var body: some View {
        YamiboRemoteImage(source: iconURL.map { YamiboImageSource(url: $0) }) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "paperclip")
                .foregroundStyle(ForumColors.brownPrimary)
        } failure: {
            Image(systemName: "paperclip")
                .foregroundStyle(ForumColors.brownPrimary)
        }
        .frame(width: 34, height: 34)
        .padding(6)
        .background(ForumColors.creamSurface, in: RoundedRectangle(cornerRadius: 8))
    }
}
