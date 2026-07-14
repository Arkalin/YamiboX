import Foundation

public struct YamiboProfile: Codable, Equatable, Sendable {
    public var uid: String
    public var username: String
    public var userGroup: String
    public var points: Int
    public var partner: Int
    public var totalPoints: Int
    public var avatarURL: URL?
    public var avatarBackgroundURL: URL?
    public var formHash: String?
    public var refreshedAt: Date

    public init(
        uid: String,
        username: String,
        userGroup: String,
        points: Int,
        partner: Int,
        totalPoints: Int,
        avatarURL: URL? = nil,
        avatarBackgroundURL: URL? = nil,
        formHash: String? = nil,
        refreshedAt: Date = .now
    ) {
        self.uid = uid
        self.username = username
        self.userGroup = userGroup
        self.points = points
        self.partner = partner
        self.totalPoints = totalPoints
        self.avatarURL = avatarURL
        self.avatarBackgroundURL = avatarBackgroundURL
        self.formHash = formHash
        self.refreshedAt = refreshedAt
    }
}

public struct YamiboUserGroupThreshold: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let minimumTotalPoints: Int
    public let readPermission: Int

    public init(name: String, minimumTotalPoints: Int, readPermission: Int) {
        self.name = name
        self.minimumTotalPoints = minimumTotalPoints
        self.readPermission = readPermission
    }
}

public struct ForumCreditProgress: Equatable, Sendable {
    public let currentGroupName: String
    public let currentTotalPoints: Int
    public let targetTotalPoints: Int

    public var fraction: Double {
        guard targetTotalPoints > 0 else { return 1 }
        return min(max(Double(currentTotalPoints) / Double(targetTotalPoints), 0), 1)
    }

    public init(currentGroupName: String, currentTotalPoints: Int, targetTotalPoints: Int) {
        self.currentGroupName = currentGroupName
        self.currentTotalPoints = currentTotalPoints
        self.targetTotalPoints = targetTotalPoints
    }
}

public enum YamiboUserGroups {
    public static let thresholds: [YamiboUserGroupThreshold] = [
        YamiboUserGroupThreshold(name: "百合种子", minimumTotalPoints: 0, readPermission: 10),
        YamiboUserGroupThreshold(name: "百合幼苗", minimumTotalPoints: 10, readPermission: 20),
        YamiboUserGroupThreshold(name: "百合花蕾", minimumTotalPoints: 100, readPermission: 30),
        YamiboUserGroupThreshold(name: "百合花开", minimumTotalPoints: 400, readPermission: 40),
        YamiboUserGroupThreshold(name: "绽放百合", minimumTotalPoints: 800, readPermission: 50),
        YamiboUserGroupThreshold(name: "百合素人", minimumTotalPoints: 1_500, readPermission: 60),
        YamiboUserGroupThreshold(name: "百合达人", minimumTotalPoints: 3_000, readPermission: 70)
    ]

    public static func currentThreshold(for totalPoints: Int) -> YamiboUserGroupThreshold? {
        thresholds
            .filter { totalPoints >= $0.minimumTotalPoints }
            .max { $0.minimumTotalPoints < $1.minimumTotalPoints }
    }

    public static func nextThreshold(for totalPoints: Int) -> YamiboUserGroupThreshold? {
        thresholds
            .filter { totalPoints < $0.minimumTotalPoints }
            .min { $0.minimumTotalPoints < $1.minimumTotalPoints }
    }

    public static func progress(for profile: YamiboProfile) -> ForumCreditProgress {
        let totalPoints = max(profile.totalPoints, 0)
        let resolvedGroupName = profile.userGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGroupName = resolvedGroupName.isEmpty
            ? currentThreshold(for: totalPoints)?.name ?? thresholds.first?.name ?? ""
            : resolvedGroupName
        let targetTotalPoints = nextThreshold(for: totalPoints)?.minimumTotalPoints ?? totalPoints
        return ForumCreditProgress(
            currentGroupName: currentGroupName,
            currentTotalPoints: totalPoints,
            targetTotalPoints: max(targetTotalPoints, totalPoints)
        )
    }
}
