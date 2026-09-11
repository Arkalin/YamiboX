import Foundation

public struct ForumComposerTarget: Equatable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case newThread, reply, editFirstPost, editReply, unknown }
    public var kind: Kind
    public var forumID: String?
    public var threadID: String?
    public var postID: String?
    public var special: String?
    public var replyPostID: String?
    public var isFirstPost: Bool { kind == .newThread || kind == .editFirstPost }

    public init(kind: Kind = .unknown, forumID: String? = nil, threadID: String? = nil, postID: String? = nil,
                special: String? = nil, replyPostID: String? = nil) {
        self.kind = kind; self.forumID = forumID; self.threadID = threadID; self.postID = postID
        self.special = special; self.replyPostID = replyPostID
    }

    public var editorURL: URL? {
        guard kind != .unknown else { return nil }
        var parts = URLComponents(url: YamiboDomain.baseURL.appendingPathComponent("forum.php"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "mod", value: "post"), .init(name: "action", value: kind == .newThread ? "newthread" : kind == .reply ? "reply" : "edit")]
        for (name, value) in [("fid", forumID), ("tid", threadID), ("pid", postID), ("special", special), ("repquote", replyPostID)] {
            if let value, !value.isEmpty { items.append(.init(name: name, value: value)) }
        }
        parts?.queryItems = items
        return parts?.url
    }
}

public struct ForumComposerAttachmentReference: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var previewURL: URL?
    public var isImage: Bool
    public init(id: String, name: String, previewURL: URL? = nil, isImage: Bool = false) {
        self.id = id; self.name = name; self.previewURL = previewURL; self.isImage = isImage
    }
}

public struct ForumComposerBackground: Equatable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let imageURL: URL
    public init(name: String, imageURL: URL) { self.name = name; self.imageURL = imageURL }
}

public struct ForumComposerContext: Equatable, Sendable {
    public enum Capability: String, Codable, Sendable { case allowed, denied, unknown }
    public var target: ForumComposerTarget
    public var bbcode: Capability
    public var images: Capability
    public var media: Capability
    public var emoticons: Capability
    public var tags: [ForumComposerTag: Capability]
    public var attachments: [ForumComposerAttachmentReference]
    public var backgrounds: [ForumComposerBackground]
    public var backgroundCatalogURL: URL?

    public init(target: ForumComposerTarget = .init(), bbcode: Capability = .unknown, images: Capability = .unknown,
                media: Capability = .unknown, emoticons: Capability = .unknown, tags: [ForumComposerTag: Capability] = [:],
                attachments: [ForumComposerAttachmentReference] = [], backgrounds: [ForumComposerBackground] = [], backgroundCatalogURL: URL? = nil) {
        self.target = target; self.bbcode = bbcode; self.images = images; self.media = media; self.emoticons = emoticons
        self.tags = tags; self.attachments = attachments; self.backgrounds = backgrounds; self.backgroundCatalogURL = backgroundCatalogURL
    }

    public func capability(for tag: ForumComposerTag) -> Capability {
        if bbcode == .denied || tags[tag] == .denied { return .denied }
        if tag == .groupid || tag.isMainPostOnly && !target.isFirstPost { return .denied }
        if tag == .postbg && backgrounds.isEmpty { return .denied }
        if [.img, .attachimg].contains(tag), images == .denied { return .denied }
        if tag.isMedia, media != .unknown { return media }
        return tags[tag] ?? (tag.isInline || tag.isParagraph ? bbcode : .unknown)
    }

    public var nestedContent: Self {
        var context = self
        context.tags[.password] = .denied
        context.tags[.postbg] = .denied
        return context
    }
}
