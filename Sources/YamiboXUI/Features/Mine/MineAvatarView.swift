import Foundation
import SwiftUI
import YamiboXCore
import UIKit

struct MineAvatarView: View {
    let profile: YamiboProfile
    let avatarLoader: YamiboProfileAvatarLoader
    let avatarReloadDate: Date?

    @State private var image: Image?

    var body: some View {
        ZStack {
            Circle()
                .fill(.secondary.opacity(0.14))

            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
        }
        .clipShape(Circle())
        .task(id: MineAvatarTaskIdentity(profile: profile, avatarReloadDate: avatarReloadDate)) {
            image = await loadImage()
        }
    }

    private func loadImage() async -> Image? {
        do {
            guard let data = try await avatarLoader.avatarData(for: profile) else { return nil }
            return platformImage(from: data)
        } catch {
            return nil
        }
    }

    private func platformImage(from data: Data) -> Image? {
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }
}

private struct MineAvatarTaskIdentity: Hashable {
    let uid: String
    let avatarURL: URL?
    let avatarReloadDate: Date?

    init(profile: YamiboProfile, avatarReloadDate: Date?) {
        uid = profile.uid
        avatarURL = profile.avatarURL
        self.avatarReloadDate = avatarReloadDate
    }
}
