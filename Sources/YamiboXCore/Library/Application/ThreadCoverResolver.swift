import Foundation

public protocol ThreadCoverPageResolving: Sendable {
    func cachedThreadPage(
        thread: ThreadIdentity,
        title: String,
        authorID: String?,
        page: Int
    ) async -> ForumThreadPage?

    func fetchThreadPage(
        thread: ThreadIdentity,
        title: String,
        authorID: String?,
        page: Int
    ) async throws -> ForumThreadPage
}

public struct ThreadCoverResolver: Sendable {
    public init() {}

    public func resolve(
        thread: ThreadIdentity,
        title: String,
        repository: any ThreadCoverPageResolving
    ) async -> URL? {
        guard let firstPage = await loadPage(
            thread: thread,
            title: title,
            authorID: nil,
            page: 1,
            repository: repository
        ) else {
            return nil
        }

        guard let owner = Self.owner(in: firstPage) else {
            return nil
        }
        return Self.findThreadCoverCandidate(in: firstPage, owner: owner)
    }

    public static func findThreadCoverCandidate(in page: ForumThreadPage?) -> URL? {
        guard let page,
              let owner = owner(in: page) else {
            return nil
        }
        return findThreadCoverCandidate(in: page, owner: owner)
    }

    private func loadPage(
        thread: ThreadIdentity,
        title: String,
        authorID: String?,
        page: Int,
        repository: any ThreadCoverPageResolving
    ) async -> ForumThreadPage? {
        if let cached = await repository.cachedThreadPage(
            thread: thread,
            title: title,
            authorID: authorID,
            page: page
        ) {
            return cached
        }
        do {
            return try await repository.fetchThreadPage(
                thread: thread,
                title: title,
                authorID: authorID,
                page: page
            )
        } catch {
            YamiboLog.library.warning("Failed to fetch thread page while resolving cover candidate for thread \(thread.tid, privacy: .public): \(error)")
            return nil
        }
    }
}

private extension ThreadCoverResolver {
    static func owner(in page: ForumThreadPage) -> BlogReaderUser? {
        page.posts.first { floorNumber(from: $0.floorText) == 1 }?.author
    }

    static func findThreadCoverCandidate(in page: ForumThreadPage, owner: BlogReaderUser) -> URL? {
        let ownerID = validOwnerID(owner.uid)
        let ownerName = trimmedNonEmpty(owner.name)
        return page.posts
            .enumerated()
            .sorted { lhs, rhs in
                let lhsFloor = floorNumber(from: lhs.element.floorText) ?? Int.max
                let rhsFloor = floorNumber(from: rhs.element.floorText) ?? Int.max
                if lhsFloor == rhsFloor {
                    return lhs.offset < rhs.offset
                }
                return lhsFloor < rhsFloor
            }
            .map(\.element)
            .filter { post in
                if let ownerID {
                    return validOwnerID(post.author.uid) == ownerID
                }
                guard let ownerName else { return false }
                return trimmedNonEmpty(post.author.name) == ownerName
            }
            .lazy
            .flatMap { post in
                post.images.compactMap(Self.coverCandidateURL(in:))
            }
            .first
    }

    static func coverCandidateURL(in image: ForumThreadPostImage) -> URL? {
        ContentCoverStore.normalizedCoverURL(from: image.url)
    }

    static func validOwnerID(_ value: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(value),
              let intValue = Int(trimmed),
              intValue > 0 else {
            return nil
        }
        return trimmed
    }

    static func floorNumber(from value: String?) -> Int? {
        guard let value = trimmedNonEmpty(value) else { return nil }
        if value == "楼主" || value == "樓主" {
            return 1
        }
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
