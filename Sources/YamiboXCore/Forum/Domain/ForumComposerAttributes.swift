import Foundation

public enum ForumComposerAlignment: String, CaseIterable, Codable, Sendable { case left, center, right }

public enum ForumComposerLength: Equatable, Codable, Sendable {
    case pixels(Double), percent(Double), automatic

    public init?(_ source: String) {
        let value = source.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "auto" { self = .automatic; return }
        let percent = value.hasSuffix("%")
        let number = percent ? String(value.dropLast()) : value
        guard let number = Double(number), number.isFinite, number > 0 else { return nil }
        self = percent ? .percent(number) : .pixels(number)
    }

    public var source: String {
        switch self {
        case let .pixels(value): Self.number(value)
        case let .percent(value): Self.number(value) + "%"
        case .automatic: "auto"
        }
    }

    public static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < Double(Int.max) ? String(Int(value)) : String(value)
    }
}

public struct ForumComposerDimensions: Equatable, Codable, Sendable {
    public var width: ForumComposerLength
    public var height: ForumComposerLength
    public init(width: ForumComposerLength = .pixels(640), height: ForumComposerLength = .pixels(360)) {
        self.width = width
        self.height = height
    }
    public var source: String { width.source + "," + height.source }
}

public struct ForumComposerParagraph: Equatable, Codable, Sendable {
    public var lineHeight: Double?
    public var firstLineIndent: Double?
    public var alignment: ForumComposerAlignment
    public init(lineHeight: Double? = nil, firstLineIndent: Double? = nil, alignment: ForumComposerAlignment = .left) {
        self.lineHeight = lineHeight
        self.firstLineIndent = firstLineIndent
        self.alignment = alignment
    }
    public var source: String {
        [lineHeight.map(ForumComposerLength.number) ?? "null", firstLineIndent.map(ForumComposerLength.number) ?? "null", alignment.rawValue].joined(separator: ", ")
    }
}

public struct ForumComposerHideCondition: Equatable, Codable, Sendable {
    public var days: Int?
    public var credits: Int?
    public init(days: Int? = nil, credits: Int? = nil) { self.days = days; self.credits = credits }
    public var source: String { [days.map { "d\($0)" }, credits.map(String.init)].compactMap { $0 }.joined(separator: ",") }
}

public enum ForumComposerAttributes: Equatable, Sendable {
    case none
    case text(String)
    case fontSize(relative: Double?, points: Double?)
    case alignment(ForumComposerAlignment)
    case paragraph(ForumComposerParagraph)
    case lineHeight(Double)
    case list(String)
    case dimensions(ForumComposerDimensions)
    case table(width: ForumComposerLength?, background: String?)
    case cell(columns: Int, rows: Int, width: ForumComposerLength?)
    case collapse(expanded: Bool, title: String)
    case hide(ForumComposerHideCondition)
    case media(type: String, dimensions: ForumComposerDimensions?)
    case begin(link: String, dimensions: ForumComposerDimensions, effect: Int, seconds: Int)
    case indexTarget(threadID: String?, postOrPageID: String)

    public static func parse(tag: ForumComposerTag, parameter: String) -> Self? {
        let pieces = parameter.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        switch tag {
        case .b, .u, .s, .sup, .sub, .indent, .quote, .code, .free, .hr, .page, .index, .password, .postbg, .attach, .attachimg, .swf, .fly, .qq, .item:
            return parameter.isEmpty ? Self.none : nil
        case .i: return parameter.isEmpty ? Self.none : (parameter == "s" ? .text(parameter) : nil)
        case .font, .ruby, .url, .email: return .text(parameter)
        case .color, .backcolor, .tr:
            if parameter.isEmpty && tag == .tr { return Self.none }
            return ForumThreadTextStyleParser.normalizedColorHex(parameter).map(Self.text)
        case .size:
            if let relative = ForumThreadTextStyleParser.relativeFontSize(fromHTMLSize: parameter) { return .fontSize(relative: relative, points: nil) }
            let raw = parameter.lowercased()
            guard raw.hasSuffix("px") || raw.hasSuffix("pt"), let value = Double(raw.dropLast(2)), value.isFinite, value > 0 else { return nil }
            return .fontSize(relative: nil, points: value * (raw.hasSuffix("pt") ? 4.0 / 3.0 : 1))
        case .align, .float:
            guard let alignment = ForumComposerAlignment(rawValue: parameter), tag != .float || alignment != .center else { return nil }
            return .alignment(alignment)
        case .p:
            guard pieces.count == 3, let alignment = ForumComposerAlignment(rawValue: pieces[2]),
                  parameter == pieces.joined(separator: ", ") else { return nil }
            let line = Double(pieces[0]), indent = Double(pieces[1])
            guard pieces[0] == "null" || line.map({ $0.isFinite && $0 > 0 }) == true,
                  pieces[1] == "null" || indent.map({ $0.isFinite && $0 >= 0 }) == true else { return nil }
            return .paragraph(.init(lineHeight: line, firstLineIndent: indent, alignment: alignment))
        case .lineh:
            guard let value = Double(parameter), value.isFinite, value > 0 else { return nil }
            return .lineHeight(value)
        case .list: return ["", "1", "a", "A"].contains(parameter) ? .list(parameter) : nil
        case .img, .flash:
            if parameter.isEmpty { return Self.none }
            let values = parameter.lowercased().replacingOccurrences(of: "x", with: ",").replacingOccurrences(of: "|", with: ",").split(separator: ",").map(String.init)
            guard values.count == 2, let width = ForumComposerLength(values[0]), let height = ForumComposerLength(values[1]) else { return nil }
            return .dimensions(.init(width: width, height: height))
        case .audio: return parameter.isEmpty || parameter == "1" ? .text(parameter) : nil
        case .media:
            if pieces.count == 1 { return .media(type: parameter, dimensions: nil) }
            guard pieces.count == 3, !pieces[0].isEmpty, let width = ForumComposerLength(pieces[1]), let height = ForumComposerLength(pieces[2]) else { return nil }
            return .media(type: pieces[0], dimensions: .init(width: width, height: height))
        case .table:
            if parameter.isEmpty { return .table(width: nil, background: nil) }
            guard pieces.count <= 2, let width = ForumComposerLength(pieces[0]) else { return nil }
            let color = pieces.count == 2 ? ForumThreadTextStyleParser.normalizedColorHex(pieces[1]) : nil
            guard pieces.count != 2 || color != nil else { return nil }
            return .table(width: width, background: color)
        case .td:
            if parameter.isEmpty { return .cell(columns: 1, rows: 1, width: nil) }
            if pieces.count == 1, let width = ForumComposerLength(parameter) { return .cell(columns: 1, rows: 1, width: width) }
            guard (2...3).contains(pieces.count), let columns = Int(pieces[0]), let rows = Int(pieces[1]),
                  (1...1000).contains(columns), (1...1000).contains(rows) else { return nil }
            let width = pieces.count == 3 ? ForumComposerLength(pieces[2]) : nil
            guard pieces.count != 3 || width != nil else { return nil }
            return .cell(columns: columns, rows: rows, width: width)
        case .collapse:
            guard let comma = parameter.firstIndex(of: ","), ["0", "1"].contains(String(parameter[..<comma])) else { return nil }
            return .collapse(expanded: parameter[..<comma] == "1", title: String(parameter[parameter.index(after: comma)...]))
        case .hide:
            if parameter.isEmpty { return .hide(.init()) }
            if parameter.hasPrefix("d"), pieces.count <= 2, let days = Int(pieces[0].dropFirst()), days >= 0 {
                let credits = pieces.count == 2 ? Int(pieces[1]) : nil
                guard pieces.count != 2 || credits.map({ $0 >= 0 }) == true else { return nil }
                return .hide(.init(days: days, credits: credits))
            }
            guard let credits = Int(parameter), credits >= 0 else { return nil }
            return .hide(.init(credits: credits))
        case .begin:
            if parameter.isEmpty { return Self.none }
            guard pieces.count == 5, let width = ForumComposerLength(pieces[1]), let height = ForumComposerLength(pieces[2]),
                  let effect = Int(pieces[3]), (0...2).contains(effect), let seconds = Int(pieces[4]), seconds >= 0 else { return nil }
            return .begin(link: pieces[0], dimensions: .init(width: width, height: height), effect: effect, seconds: seconds)
        case .groupid: return Int(parameter).map { $0 > 0 ? .text(parameter) : nil } ?? nil
        case .indexEntry:
            guard (1...2).contains(pieces.count), pieces.allSatisfy({ Int($0).map { $0 > 0 } == true }) else { return nil }
            return .indexTarget(threadID: pieces.count == 2 ? pieces[0] : nil, postOrPageID: pieces.last!)
        }
    }
}

public enum ForumComposerSyntax {
    public static func normalizedColor(_ value: String) -> String? { ForumThreadTextStyleParser.normalizedColorHex(value) }

    public static func markup(tag: ForumComposerTag, parameter: String = "", body: String = "") throws -> String {
        guard !parameter.contains("]"), !parameter.contains("["), !parameter.contains("\n"), !parameter.contains("\r"),
              ForumComposerAttributes.parse(tag: tag, parameter: parameter) != nil else { throw ForumComposerDocumentError.invalidParameter }
        if tag == .indexEntry { return "[#\(parameter)]" + body }
        let opening = "[\(tag.rawValue)\(parameter.isEmpty ? "" : "=\(parameter)")]"
        return opening + (tag.isSingleton ? "" : body + "[/\(tag.rawValue)]")
    }

    public static func safeURL(_ value: String, relativeTo baseURL: URL = YamiboDomain.baseURL, email: Bool = false) -> URL? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isNewline }), !raw.contains("]"), !raw.contains("[") else { return nil }
        let candidate = email && !raw.lowercased().hasPrefix("mailto:") ? "mailto:" + raw : raw
        guard let url = URL(string: candidate, relativeTo: baseURL)?.absoluteURL,
              url.user == nil, url.password == nil else { return nil }
        if url.scheme?.lowercased() == "mailto" { return url.path.contains("@") ? url : nil }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return ForumWebPagePolicy.secureURL(url)
    }
}
