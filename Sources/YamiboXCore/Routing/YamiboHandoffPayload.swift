import Foundation

/// A portable reading position, deliberately independent of local library/download identities.
public struct YamiboHandoffPayload: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case novel, manga, thread }

    public let version: Int
    public let site: URL
    public let kind: Kind
    public let title: String
    public let threadID: String
    public let forumID: String?
    public let authorID: String?
    public let view: Int
    public let novelPosition: NovelPosition?
    public let originalThreadID: String?
    public let imageIndex: Int?
    public let smartManga: Bool?
    public let threadPosition: ThreadExplicitReadingState?

    public static let maximumEncodedSize = 2_800

    private init(kind: Kind, title: String, threadID: String, forumID: String?, authorID: String? = nil,
                 view: Int, novelPosition: NovelPosition? = nil, originalThreadID: String? = nil,
                 imageIndex: Int? = nil, smartManga: Bool? = nil, threadPosition: ThreadExplicitReadingState? = nil) {
        version = 1
        site = YamiboForumEnvironment.current.baseURL
        self.kind = kind
        self.title = String(title.prefix(100))
        self.threadID = threadID
        self.forumID = forumID
        self.authorID = authorID
        self.view = view
        self.novelPosition = novelPosition
        self.originalThreadID = originalThreadID
        self.imageIndex = imageIndex
        self.smartManga = smartManga
        self.threadPosition = threadPosition
    }

    public static func novel(_ context: NovelLaunchContext) -> Self? {
        guard !context.isPreview, let point = context.initialResumePoint else { return nil }
        return Self(kind: .novel, title: context.threadTitle, threadID: context.threadID,
                    forumID: context.forumID, authorID: context.authorID, view: point.view, novelPosition: NovelPosition(point))
    }

    public static func manga(_ context: MangaLaunchContext) -> Self? {
        guard !context.isPreview else { return nil }
        return Self(kind: .manga, title: context.displayTitle, threadID: context.chapterTID,
                    forumID: context.forumID, view: context.chapterView, originalThreadID: context.originalThreadID,
                    imageIndex: context.initialPage, smartManga: context.isSmartModeEnabled)
    }

    public static func thread(_ context: ThreadNovelLaunchContext, position: ThreadExplicitReadingState) -> Self {
        Self(kind: .thread, title: context.title, threadID: context.thread.tid, forumID: context.thread.fid,
             authorID: position.authorID, view: position.page, threadPosition: position)
    }

    public func encoded(environment: YamiboForumEnvironment = .current) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard isValid(environment: environment), let data = try? encoder.encode(self),
              data.count <= Self.maximumEncodedSize else { return nil }
        return data
    }

    public static func decode(_ data: Data, environment: YamiboForumEnvironment = .current) -> Self? {
        guard data.count <= maximumEncodedSize,
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.isValid(environment: environment) else { return nil }
        return payload
    }

    private func isValid(environment: YamiboForumEnvironment) -> Bool {
        guard version == 1, site == environment.baseURL, Self.validID(threadID),
              forumID.map(Self.validID) ?? true, authorID.map(Self.validID) ?? true,
              (1...1_000_000).contains(view), title.count <= 100 else { return false }
        switch kind {
        case .novel:
            guard let point = novelPosition, originalThreadID == nil, imageIndex == nil,
                  smartManga == nil, threadPosition == nil else { return false }
            return point.view == view && (0...100_000_000).contains(point.displayedTextOffset)
                && (0...1_000_000).contains(point.chapterOrdinal)
                && point.segmentProgress.isFinite && (0...1).contains(point.segmentProgress)
                && (point.authorID.map(Self.validID) ?? true)
                && (point.chapterIdentity?.rawValue.utf8.count ?? 0) <= 256
                && (point.textSegmentIdentity?.rawValue.utf8.count ?? 0) <= 256
                && (point.chapterTitle?.count ?? 0) <= 100
        case .manga:
            return novelPosition == nil && threadPosition == nil && authorID == nil
                && originalThreadID.map(Self.validID) == true && smartManga != nil
                && imageIndex.map { (0...1_000_000).contains($0) } == true
        case .thread:
            guard let position = threadPosition, novelPosition == nil, originalThreadID == nil,
                  imageIndex == nil, smartManga == nil else { return false }
            return position.page == view && position.authorID == authorID
                && (position.anchorPostID.map(Self.validID) ?? true)
                && (position.authorID.map(Self.validID) ?? true)
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
            && UInt64(value).map { $0 > 0 } == true
    }

    public var readerRoute: ReaderResumeRoute? {
        guard isValid(environment: .current) else { return nil }
        return switch kind {
        case .novel:
            .novel(NovelLaunchContext(threadID: threadID, threadTitle: title, source: .resume,
                                      initialView: view, authorID: authorID, initialResumePoint: novelPosition?.resumePoint, forumID: forumID))
        case .manga:
            .manga(MangaLaunchContext(originalThreadID: originalThreadID ?? threadID, chapterTID: threadID,
                                      displayTitle: title, source: .resume, chapterView: view,
                                      initialPage: imageIndex ?? 0, isSmartModeEnabled: smartManga ?? false, forumID: forumID))
        case .thread: nil
        }
    }

    public var threadContext: ThreadNovelLaunchContext? {
        guard isValid(environment: .current), kind == .thread, let threadPosition else { return nil }
        return ThreadNovelLaunchContext(thread: ThreadIdentity(tid: threadID, fid: forumID), title: title,
                                        initialPage: view, authorID: authorID, explicitReadingState: threadPosition)
    }

    public var webpageURL: URL {
        let url = YamiboRoute.threadByID(tid: threadID, page: view,
                                         authorID: authorID, reverse: threadPosition?.isReverseOrder ?? false).url
        guard let postID = threadPosition?.anchorPostID else { return url }
        // Keep the filter/page query; the fragment doesn't change Discuz's filtered pagination.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = "pid\(postID)"
        return components.url ?? url
    }

    /// Decode untrusted numbers before constructing the domain type, whose initializer clamps them.
    public struct NovelPosition: Codable, Hashable, Sendable {
        let view: Int
        let chapterIdentity: NovelChapterIdentity?
        let textSegmentIdentity: NovelTextSegmentIdentity?
        let displayedTextOffset: Int
        let chapterOrdinal: Int
        let chapterTitle: String?
        let segmentProgress: Double
        let authorID: String?
        let readingModeHint: ReaderReadingMode

        init(_ point: NovelResumePoint) {
            view = point.view
            chapterIdentity = point.chapterIdentity
            textSegmentIdentity = point.textSegmentIdentity
            displayedTextOffset = point.displayedTextOffset
            chapterOrdinal = point.chapterOrdinal
            chapterTitle = point.chapterTitle.map { String($0.prefix(100)) }
            segmentProgress = point.segmentProgress
            authorID = point.authorID
            readingModeHint = point.readingModeHint
        }

        var resumePoint: NovelResumePoint {
            NovelResumePoint(view: view, chapterIdentity: chapterIdentity, textSegmentIdentity: textSegmentIdentity,
                             displayedTextOffset: displayedTextOffset, chapterOrdinal: chapterOrdinal,
                             chapterTitle: chapterTitle, segmentProgress: segmentProgress, authorID: authorID,
                             readingModeHint: readingModeHint)
        }
    }
}

public struct ThreadExplicitReadingState: Codable, Hashable, Sendable {
    public var page: Int
    public var anchorPostID: String?
    /// Non-nil means only the thread starter's posts are shown.
    public var authorID: String?
    public var isReverseOrder: Bool

    public init(page: Int, anchorPostID: String?, authorID: String?, isReverseOrder: Bool) {
        self.page = page
        self.anchorPostID = anchorPostID
        self.authorID = authorID
        self.isReverseOrder = isReverseOrder
    }
}
