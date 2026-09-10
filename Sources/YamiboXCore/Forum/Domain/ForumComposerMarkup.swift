import Foundation

public enum ForumComposerFormat: Equatable, Sendable {
    case bbcode, html, plainText
}

public struct ForumComposerWrapper: Equatable, Sendable {
    public let id: String
    public let name: String
    public let opening: String
    public let closing: String
    public let style: ForumThreadTextStyle
    public let link: URL?
    public let isQuote: Bool

    /// Equivalent tags share toolbar behavior without rewriting their source.
    public var formattingName: String {
        switch name {
        case "strong": "b"
        case "em": "i"
        case "strike": "s"
        case "blockquote": "quote"
        default: name
        }
    }

    public init(id: String, name: String, opening: String, closing: String,
                style: ForumThreadTextStyle = .init(), link: URL? = nil, isQuote: Bool = false) {
        self.id = id
        self.name = name
        self.opening = opening
        self.closing = closing
        self.style = style
        self.link = link
        self.isQuote = isQuote
    }
}

public struct ForumComposerRun: Sendable {
    public var text: String
    public let originalText: String
    public let source: String
    public var wrappers: [ForumComposerWrapper]
    public let imageURL: URL?
    public let isAttachment: Bool
    public let isLiteral: Bool

    public init(text: String, source: String, wrappers: [ForumComposerWrapper] = [],
                imageURL: URL? = nil, isAttachment: Bool = false, isLiteral: Bool = false) {
        self.text = text
        originalText = text
        self.source = source
        self.wrappers = wrappers
        self.imageURL = imageURL
        self.isAttachment = isAttachment
        self.isLiteral = isLiteral
    }
}

/// The editing model keeps original delimiters alongside native text runs.
/// Unknown markup stays literal instead of disappearing in a lossy conversion.
public enum ForumComposerMarkup {
    public static func parse(_ source: String, format: ForumComposerFormat) -> [ForumComposerRun] {
        ForumComposerMarkupParser.parse(source, format: format)
    }

    public static func serialize(_ runs: [ForumComposerRun], format: ForumComposerFormat) -> String {
        var source = ""
        var active: [ForumComposerWrapper] = []
        for run in runs where !run.text.isEmpty {
            let common = zip(active, run.wrappers).prefix { $0 == $1 }.count
            source += active.dropFirst(common).reversed().map(\.closing).joined()
            source += run.wrappers.dropFirst(common).map(\.opening).joined()
            active = run.wrappers
            if run.text == run.originalText {
                source += run.source
            } else if format == .html && !run.isLiteral {
                source += escapeHTML(run.text)
            } else {
                source += run.text
            }
        }
        return source + active.reversed().map(\.closing).joined()
    }

    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
