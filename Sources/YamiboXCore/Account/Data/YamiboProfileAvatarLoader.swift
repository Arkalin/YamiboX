import Foundation

public actor YamiboProfileAvatarLoader {
    private let sessionStore: any SessionStoring
    private let imageData: @Sendable (YamiboImageSource) async throws -> Data
    private var cachedData: [RequestKey: Data] = [:]
    private var inFlightTasks: [RequestKey: Task<Data, Error>] = [:]

    public init(
        sessionStore: any SessionStoring,
        imageData: (@Sendable (YamiboImageSource) async throws -> Data)? = nil
    ) {
        self.sessionStore = sessionStore
        self.imageData = imageData ?? { source in
            try await YamiboImagePipeline.shared.data(for: source)
        }
    }

    public func avatarData(for profile: YamiboProfile) async throws -> Data? {
        guard let avatarURL = profile.avatarURL else { return nil }

        let sessionState = await sessionStore.load()
        let key = RequestKey(
            avatarURL: avatarURL,
            profileUID: profile.uid,
            accountUID: sessionState.accountUID,
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
        )
        if let data = cachedData[key] {
            return data
        }
        if let task = inFlightTasks[key] {
            return try await task.value
        }

        let task = Task<Data, Error> { [imageData] in
            try await imageData(YamiboImageSource(url: avatarURL))
        }
        inFlightTasks[key] = task
        do {
            let data = try await task.value
            cachedData[key] = data
            inFlightTasks.removeValue(forKey: key)
            return data
        } catch {
            inFlightTasks.removeValue(forKey: key)
            throw error
        }
    }

    private struct RequestKey: Hashable {
        let avatarURL: URL
        let profileUID: String
        let accountUID: String?
        let cookie: String
        let userAgent: String
    }
}
