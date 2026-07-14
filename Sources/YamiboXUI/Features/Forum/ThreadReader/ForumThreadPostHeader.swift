import SwiftUI
import YamiboXCore

struct ForumThreadPostHeader: View {
    let post: ForumThreadPost
    let onUserTap: (String, String?) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ForumAvatarView(url: post.author.avatarURL, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                if let uid = post.author.uid {
                    Button {
                        onUserTap(uid, post.author.name)
                    } label: {
                        Text(post.author.name)
                            .expandedHitTarget(width: 0)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumColors.brownPrimary)
                } else {
                    Text(post.author.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForumColors.textDark)
                }

                HStack(spacing: 8) {
                    if let floorText = post.floorText {
                        Text(floorText)
                    }
                    if let postedAtText = post.postedAtText {
                        Text(postedAtText)
                    }
                }
                .font(.caption)
                .foregroundStyle(ForumColors.brownLight)
            }

            Spacer(minLength: 0)

            if !post.manageActions.isEmpty {
                ForumThreadManageActionsView(actions: post.manageActions, onURLTap: onURLTap)
            }

            if post.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForumColors.secondaryText)
                    .accessibilityLabel(L10n.string("forum.thread.pinned"))
            }
        }
    }
}

private struct ForumThreadManageActionsView: View {
    let actions: [ForumThreadManageAction]
    let onURLTap: (URL) -> Void

    var body: some View {
        if let singleAction = actions.single {
            Button {
                onURLTap(singleAction.url)
            } label: {
                Text(singleAction.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForumColors.orangeAccent)
                    .expandedHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("forum.thread.manage_action"))
        } else {
            Menu {
                ForEach(actions) { action in
                    Button(action.title) {
                        onURLTap(action.url)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ForumColors.orangeAccent)
                    .frame(width: 32, height: 32)
                    .expandedHitTarget()
            }
            .accessibilityLabel(L10n.string("forum.thread.manage_action"))
        }
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
