import Foundation
import SwiftUI
import YamiboXCore

struct MineProfileSection: View {
    let profile: YamiboProfile?
    let avatarLoader: YamiboProfileAvatarLoader
    let avatarReloadDate: Date?
    let isRefreshing: Bool
    let isInteractionDisabled: Bool
    let showProfile: () -> Void

    var body: some View {
        Section {
            if let profile {
                Button(action: showProfile) {
                    MineProfileCard(
                        profile: profile,
                        avatarLoader: avatarLoader,
                        avatarReloadDate: avatarReloadDate
                    )
                }
                .buttonStyle(.plain)
                .disabled(isInteractionDisabled)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } else {
                MineProfileLoadingCard(isRefreshing: isRefreshing)
                    .allowsHitTesting(!isInteractionDisabled)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }
        }
    }
}

struct MineLoggedOutProfileSection: View {
    let isInteractionDisabled: Bool
    let showLogin: () -> Void

    var body: some View {
        Section {
            Button(action: showLogin) {
                MineLoggedOutProfileCard()
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .accessibilityLabel(L10n.string("mine.tap_to_login"))
            .accessibilityHint(L10n.string("mine.login_card_hint"))
        }
    }
}

private struct MineLoggedOutProfileCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.14))

                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            Text(L10n.string("mine.tap_to_login"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 96)
        .contentShape(Rectangle())
    }
}

private struct MineProfileCard: View {
    let profile: YamiboProfile
    let avatarLoader: YamiboProfileAvatarLoader
    let avatarReloadDate: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            MineAvatarView(
                profile: profile,
                avatarLoader: avatarLoader,
                avatarReloadDate: avatarReloadDate
            )
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 10) {
                MineProfileIdentityRow(username: profile.username, uid: profile.uid)
                MineCreditProgressView(progress: YamiboUserGroups.progress(for: profile))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 96)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.string("mine.profile_card_view_profile_hint"))
    }
}

private struct MineProfileIdentityRow: View {
    let username: String
    let uid: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(username.isEmpty ? L10n.string("mine.unknown_user") : username)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                MineUIDText(uid: uid)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(username.isEmpty ? L10n.string("mine.unknown_user") : username)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                MineUIDText(uid: uid)
            }
        }
    }
}

private struct MineUIDText: View {
    let uid: String

    var body: some View {
        Text(L10n.string("mine.uid_format", uid))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MineCreditProgressView: View {
    let progress: ForumCreditProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
                .tint(.accentColor)

            HStack(spacing: 8) {
                Text(progress.currentGroupName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(L10n.string("mine.credit_progress_format", progress.currentTotalPoints, progress.targetTotalPoints))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct MineProfileLoadingCard: View {
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("common.loading"))
                    .font(.title3.weight(.semibold))
                ProgressView()
                    .opacity(isRefreshing ? 1 : 0)
            }
        }
        .frame(minHeight: 96)
    }
}
