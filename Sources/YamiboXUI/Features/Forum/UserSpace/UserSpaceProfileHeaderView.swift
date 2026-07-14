import SwiftUI
import YamiboXCore

struct UserSpaceProfileHeaderView: View {
    let profile: UserSpaceProfile
    let isSelf: Bool
    let onSectionTap: (UserSpaceSection, UserSpaceSubPage) -> Void
    let beginAddFriend: () -> Void
    let onMessageCenterTap: (MessageCenterTab) -> Void
    let onWebTap: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                YamiboRemoteImage(source: (profile.avatarBackgroundURL ?? profile.avatarURL).map { YamiboImageSource(url: $0) }) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle().fill(ForumColors.brownDeep.opacity(0.24))
                } failure: {
                    Rectangle().fill(ForumColors.brownDeep.opacity(0.24))
                }
                .frame(height: 172)
                .clipped()

                Rectangle()
                    .fill(.black.opacity(0.38))

                VStack(spacing: 10) {
                    YamiboRemoteImage(source: profile.avatarURL.map { YamiboImageSource(url: $0) }) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.white.opacity(0.8))
                    } failure: {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())

                    Text(profile.username)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 172)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            UserSpaceStatsView(profile: profile)
            UserSpaceActionGridView(
                isSelf: isSelf,
                onSectionTap: onSectionTap,
                beginAddFriend: beginAddFriend,
                onMessageCenterTap: onMessageCenterTap,
                onWebTap: onWebTap
            )

            if let signature = profile.signature {
                UserSpaceSignatureView(signature: signature)
            }

            UserSpaceInfoTableView(rows: profile.infoRows, onWebTap: onWebTap)
        }
    }
}

private struct UserSpaceActionGridView: View {
    let isSelf: Bool
    let onSectionTap: (UserSpaceSection, UserSpaceSubPage) -> Void
    let beginAddFriend: () -> Void
    let onMessageCenterTap: (MessageCenterTab) -> Void
    let onWebTap: (URL) -> Void

    private var actions: [UserSpaceProfileAction] {
        if isSelf {
            [
                UserSpaceProfileAction(section: .threads, subPage: .threads, icon: "text.bubble", titleKey: "user_space.my_threads"),
                UserSpaceProfileAction(section: .blogs, subPage: .friendBlogs, icon: "book.pages", titleKey: "user_space.my_blogs"),
                UserSpaceProfileAction(section: .friends, subPage: .friends, icon: "person.2", titleKey: "user_space.my_friends"),
                UserSpaceProfileAction(messageCenterTab: .privateMessages, icon: "bell.badge", titleKey: "user_space.message_alerts")
            ]
        } else {
            [
                UserSpaceProfileAction(section: .threads, subPage: .threads, icon: "text.bubble", titleKey: "user_space.other_threads"),
                UserSpaceProfileAction(section: .blogs, subPage: .myBlogs, icon: "book.pages", titleKey: "user_space.other_blogs"),
                UserSpaceProfileAction(section: .threads, subPage: .replies, icon: "arrowshape.turn.up.left", titleKey: "user_space.other_replies"),
                UserSpaceProfileAction(subPage: nil, icon: "person.badge.plus", titleKey: "user_space.add_friend")
            ]
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(actions) { action in
                Button {
                    if let section = action.section, let subPage = action.subPage {
                        onSectionTap(section, subPage)
                    } else if let messageCenterTab = action.messageCenterTab {
                        onMessageCenterTap(messageCenterTab)
                    } else if let webURL = action.webURL {
                        onWebTap(webURL)
                    } else {
                        beginAddFriend()
                    }
                } label: {
                    Label(L10n.string(action.titleKey), systemImage: action.icon)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)
                .tint(ForumColors.brownEmphasis)
            }
        }
        .padding(13)
        .forumCardBackground()
        .padding(.top, 10)
    }

}

private struct UserSpaceProfileAction: Identifiable {
    let section: UserSpaceSection?
    let subPage: UserSpaceSubPage?
    let webURL: URL?
    let messageCenterTab: MessageCenterTab?
    let icon: String
    let titleKey: String

    init(
        section: UserSpaceSection? = nil,
        subPage: UserSpaceSubPage? = nil,
        webURL: URL? = nil,
        messageCenterTab: MessageCenterTab? = nil,
        icon: String,
        titleKey: String
    ) {
        self.section = section
        self.subPage = subPage
        self.webURL = webURL
        self.messageCenterTab = messageCenterTab
        self.icon = icon
        self.titleKey = titleKey
    }

    var id: String {
        [section?.rawValue, subPage?.rawValue, webURL?.absoluteString, messageCenterTab?.rawValue, titleKey]
            .compactMap { $0 }
            .joined(separator: "|")
    }
}

private struct UserSpaceStatsView: View {
    let profile: UserSpaceProfile

    var body: some View {
        HStack(spacing: 0) {
            UserSpaceStatView(label: L10n.string("user_space.total_points"), value: profile.totalPoints.map(String.init) ?? "-")
            UserSpaceStatView(label: L10n.string("user_space.points"), value: profile.points.map(String.init) ?? "-")
            UserSpaceStatView(label: L10n.string("user_space.partner"), value: profile.partner.map(String.init) ?? "-")
        }
        .padding(.vertical, 12)
        .forumCardBackground()
        .padding(.top, 10)
    }
}

private struct UserSpaceStatView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(ForumColors.textDark)
            Text(label)
                .font(.caption)
                .foregroundStyle(ForumColors.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct UserSpaceSignatureView: View {
    let signature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("user_space.signature"))
                .font(.headline)
                .foregroundStyle(ForumColors.brownPrimary)
            Text(signature)
                .font(.subheadline)
                .foregroundStyle(ForumColors.secondaryText)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
        .padding(.top, 10)
    }
}

private struct UserSpaceInfoTableView: View {
    let rows: [UserSpaceInfoRow]
    let onWebTap: (URL) -> Void

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("user_space.profile"))
                    .font(.headline)
                    .foregroundStyle(ForumColors.brownPrimary)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(ForumColors.secondaryText)
                        Spacer(minLength: 8)
                        if let url = row.url {
                            Button {
                                onWebTap(url)
                            } label: {
                                Text(row.value)
                                    .multilineTextAlignment(.trailing)
                                    .expandedHitTarget(width: 0)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ForumColors.brownPrimary)
                        } else {
                            Text(row.value)
                                .foregroundStyle(ForumColors.textDark)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .font(.subheadline)
                    Divider()
                }
            }
            .padding(13)
            .forumCardBackground()
            .padding(.top, 10)
        }
    }
}
