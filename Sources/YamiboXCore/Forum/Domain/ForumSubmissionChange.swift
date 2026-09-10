import Foundation

public struct ForumSubmissionChange: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        case post(mode: ForumPostEditorMode, threadID: String?, forumID: String?, replyURL: URL?)
        case blog(blogID: String?)
    }

    public init?(form: ForumForm, sourceURL: URL, response: ForumPageDocument) {
        guard response.submissionAccepted else { return nil }
        let urls = [form.actionURL, sourceURL]
        func value(_ name: String) -> String? {
            urls.compactMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == name })?.value?.nilIfBlank
            }.first ?? form.hiddenValues.first(where: { $0.name == name })?.value.nilIfBlank
        }
        let destination = [response.continuationURL, response.url].compactMap { $0 }.first {
            guard ForumWebPagePolicy.requiresForumHandling($0) else { return false }
            switch ForumRouteResolver.resolve(url: $0) {
            case .thread, .blog: return true
            default: return false
            }
        }
        switch form.kind {
        case .thread:
            guard let mode = ForumPostEditorMode(url: form.actionURL) ?? ForumPostEditorMode(url: sourceURL) else { return nil }
            let threadID = value("tid") ?? value("ptid") ?? destination.flatMap(YamiboThreadURLCanonicalizer.threadID)
            let isModerated = ["审核", "審核"].contains { response.message?.contains($0) == true }
            let replyURL = destination.flatMap { url -> URL? in
                guard mode == .reply, !isModerated,
                      case .thread = ForumRouteResolver.resolve(url: url),
                      YamiboThreadURLCanonicalizer.threadID(from: url) == threadID else { return nil }
                return url
            }
            kind = .post(mode: mode, threadID: threadID, forumID: value("fid"), replyURL: replyURL)
        case .blog:
            let destinationID: String? = destination.flatMap {
                if case let .blog(blogID, _, _) = ForumRouteResolver.resolve(url: $0) { return blogID }
                return nil
            }
            kind = .blog(blogID: value("blogid") ?? destinationID)
        case .standard:
            return nil
        }
    }
}
