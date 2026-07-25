import SwiftUI
import YamiboXCore

struct ForumThreadSummaryRowView: View {
    let thread: ForumThreadSummary
    let onThreadTap: () -> Void
    let onAuthorTap: (String, String?) -> Void
    /// Long-press menu for opening this one thread with a different reader
    /// than its board is configured for. `nil` (the default) leaves the card
    /// without a context menu entirely — an empty menu would still swallow
    /// the long press.
    var onReaderOverrideTap: ((YamiboThreadReaderOverride) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForumThreadSummaryMetaView(
                authorName: thread.authorName,
                authorID: thread.authorID,
                authorAvatarURL: thread.authorAvatarURL,
                lastActivityText: thread.lastActivityText,
                onAuthorTap: onAuthorTap
            )

            Button(action: onThreadTap) {
                VStack(alignment: .leading, spacing: 10) {
                    ForumThreadSummaryTitleView(title: thread.title, isPoll: thread.isPoll)

                    if let description = thread.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(ForumColors.brownPrimary.opacity(0.65))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForumThreadSummaryFooterView(
                        tag: thread.tag,
                        viewCount: thread.viewCount,
                        replyCount: thread.replyCount
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .forumCardBackground()
        .forumThreadReaderOverrideContextMenu(onSelect: onReaderOverrideTap)
        .accessibilityIdentifier("forum-thread-row-\(thread.tid)")
    }
}

extension View {
    /// Long-press menu for opening one thread with a reader other than the one
    /// its board is configured for. Shared by every row that can open a thread
    /// (summary cards and pinned rows); pass `nil` where no thread is behind
    /// the row — an announcement links to a web page, which has no reading
    /// mode to choose.
    func forumThreadReaderOverrideContextMenu(
        onSelect: ((YamiboThreadReaderOverride) -> Void)?
    ) -> some View {
        modifier(ForumThreadReaderOverrideContextMenu(onSelect: onSelect))
    }
}

/// Applies the reading-mode context menu only when a handler exists: an
/// always-present `.contextMenu` whose body happens to be empty still turns
/// every long press on the row into a menu-less preview.
private struct ForumThreadReaderOverrideContextMenu: ViewModifier {
    let onSelect: ((YamiboThreadReaderOverride) -> Void)?

    func body(content: Content) -> some View {
        if let onSelect {
            content.contextMenu {
                Section(L10n.string("forum.thread.reader_override")) {
                    ForumThreadReaderOverrideButton(
                        title: L10n.string("forum.board.reader_settings.mode.plain"),
                        systemImage: "text.bubble",
                        action: { onSelect(.plainThread) }
                    )
                    ForumThreadReaderOverrideButton(
                        title: L10n.string("forum.board.reader_settings.mode.novel"),
                        systemImage: "book",
                        action: { onSelect(.novel) }
                    )
                    ForumThreadReaderOverrideButton(
                        title: L10n.string("forum.board.reader_settings.mode.manga"),
                        systemImage: "photo.stack",
                        action: { onSelect(.manga) }
                    )
                }
            }
        } else {
            content
        }
    }
}

private struct ForumThreadReaderOverrideButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct ForumThreadSummaryMetaView: View {
    let authorName: String?
    let authorID: String?
    let authorAvatarURL: URL?
    let lastActivityText: String?
    let onAuthorTap: (String, String?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let authorID {
                Button {
                    onAuthorTap(authorID, authorName)
                } label: {
                    ForumThreadSummaryAuthorView(
                        authorName: authorName,
                        authorAvatarURL: authorAvatarURL
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(authorName ?? L10n.string("forum.thread.author"))
            } else {
                ForumThreadSummaryAuthorView(
                    authorName: authorName,
                    authorAvatarURL: authorAvatarURL
                )
            }

            if let lastActivityText {
                Text(lastActivityText)
                    .font(.caption2)
                    .foregroundStyle(ForumColors.tertiaryText)
                    .lineLimit(1)
            }
        }
    }
}

private struct ForumThreadSummaryAuthorView: View {
    let authorName: String?
    let authorAvatarURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            ForumAvatarView(url: authorAvatarURL, size: 26)
                .accessibilityHidden(true)

            if let authorName {
                Text(authorName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ForumColors.brownPrimary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ForumThreadSummaryTitleView: View {
    let title: String
    let isPoll: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isPoll {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.caption)
                    .foregroundStyle(ForumColors.secondaryText)
            }

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(ForumColors.textDark)
                .multilineTextAlignment(.leading)
        }
    }
}

private struct ForumThreadSummaryFooterView: View {
    let tag: String?
    let viewCount: Int?
    let replyCount: Int?

    var body: some View {
        HStack(spacing: 12) {
            if let viewCount {
                Label(String(viewCount), systemImage: "eye")
            }
            if let replyCount {
                Label(String(replyCount), systemImage: "bubble.right")
            }

            Spacer(minLength: 0)

            if let tag {
                Text("#\(tag)")
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ForumColors.accentFill, in: Capsule())
            }
        }
        .font(.caption)
        .foregroundStyle(ForumColors.secondaryText)
    }
}
