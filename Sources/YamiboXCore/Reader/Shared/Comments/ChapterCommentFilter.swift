import Foundation

public enum ChapterCommentFilterScope: String, CaseIterable, Sendable {
    case ratings
    case discussions

    public var title: String { L10n.string("settings.chapter_comments.\(rawValue)") }
}

public struct ChapterCommentFilterRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var pattern: String

    public init(id: String = UUID().uuidString, pattern: String) {
        self.id = id
        self.pattern = pattern
    }
}

public struct ChapterCommentFilterGroup: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var rules: [ChapterCommentFilterRule]

    public init(isEnabled: Bool = false, rules: [ChapterCommentFilterRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public static func defaults(for scope: ChapterCommentFilterScope) -> Self {
        guard scope == .ratings else { return .init() }
        let phrases = ["你太可爱", "你太可愛", "好萌好萌好萌", "我很赞同", "我很贊同", "精品文章", "原创内容", "原創內容"]
        return .init(isEnabled: true, rules: phrases.enumerated().map {
            .init(id: "default-rating-\($0.offset)", pattern: "\\A\($0.element)\\z")
        })
    }
}

public struct ChapterCommentFilterSettings: Codable, Hashable, Sendable {
    public var ratings: ChapterCommentFilterGroup
    public var discussions: ChapterCommentFilterGroup

    public init(ratings: ChapterCommentFilterGroup = .defaults(for: .ratings),
                discussions: ChapterCommentFilterGroup = .defaults(for: .discussions)) {
        self.ratings = ratings
        self.discussions = discussions
    }

    public subscript(scope: ChapterCommentFilterScope) -> ChapterCommentFilterGroup {
        get { scope == .ratings ? ratings : discussions }
        set {
            switch scope {
            case .ratings: ratings = newValue
            case .discussions: discussions = newValue
            }
        }
    }
}

public struct ChapterCommentViewer: Equatable, Sendable {
    public let uid: String
    public let username: String?

    public init?(session: SessionState, profile: YamiboProfile?) {
        guard session.isLoggedIn, session.hasValidAuthenticationCookie,
              let uid = session.accountUID, !uid.isEmpty else { return nil }
        self.uid = uid
        self.username = profile?.uid == uid ? profile?.username : nil
    }

    func owns(_ comment: ChapterComment) -> Bool {
        if let authorUID = comment.authorUID { return authorUID == uid }
        guard let username, !username.isEmpty else { return false }
        return comment.authorName == username
    }
}

public enum ChapterCommentPatternError: LocalizedError {
    case empty
    case duplicate

    public var errorDescription: String? {
        L10n.string(self == .empty ? "settings.chapter_comments.empty_pattern" : "settings.chapter_comments.duplicate_pattern")
    }
}

/// Actor isolation keeps ICU compilation and matching off the presentation actor.
public actor ChapterCommentFilterEngine {
    public enum Match: Equatable, Sendable { case matched, unmatched, timedOut }

    private var cachedRules: [ChapterCommentFilterRule] = []
    private var compiled: [String: NSRegularExpression] = [:]
    private let budget: Duration

    public init(matchBudget: Duration = .milliseconds(50)) {
        budget = matchBudget
    }

    public func validate(pattern: String) throws {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChapterCommentPatternError.empty
        }
        _ = try NSRegularExpression(pattern: pattern)
    }

    public func preview(pattern: String, text: String) throws -> Match {
        try validate(pattern: pattern)
        return try match(try NSRegularExpression(pattern: pattern), text: Self.normalized(text))
    }

    public func filter(_ comments: [ChapterComment], settings: ChapterCommentFilterSettings,
                       viewer: ChapterCommentViewer?) throws -> [ChapterComment] {
        try Task.checkCancellation()
        let rules = settings.ratings.rules + settings.discussions.rules
        if cachedRules != rules {
            var nextCompiled: [String: NSRegularExpression] = [:]
            for rule in rules where nextCompiled[rule.pattern] == nil {
                try Task.checkCancellation()
                guard !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                nextCompiled[rule.pattern] = try? NSRegularExpression(pattern: rule.pattern)
            }
            // Publish both halves together; a cancelled build must not corrupt
            // the previous version when the user immediately restores its rules.
            compiled = nextCompiled
            cachedRules = rules
        }
        var skipped = Set<String>()
        return try comments.filter { comment in
            try Task.checkCancellation()
            if viewer?.owns(comment) == true { return true }
            let group = settings[comment.source == .ratingReason ? .ratings : .discussions]
            guard group.isEnabled else { return true }
            let text = Self.normalized(comment.bodyBlocks?.map(\.text).joined(separator: " ") ?? comment.body)
            for rule in group.rules where !skipped.contains(rule.pattern) {
                guard let expression = compiled[rule.pattern] else { continue }
                switch try match(expression, text: text) {
                case .matched: return false
                case .unmatched: continue
                case .timedOut:
                    skipped.insert(rule.pattern)
                    return true
                }
            }
            return true
        }
    }

    private func match(_ expression: NSRegularExpression, text: String) throws -> Match {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + budget
        var result = Match.unmatched
        expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                    range: NSRange(text.startIndex..., in: text)) { match, flags, stop in
            if Task.isCancelled || ContinuousClock.now >= deadline || flags.contains(.internalError) {
                result = .timedOut
                stop.pointee = true
            } else if match != nil {
                result = .matched
                stop.pointee = true
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
