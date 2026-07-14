import Foundation

/// Parses inline presentation markup (`<font>` attributes, CSS `style` declarations)
/// into `ForumThreadTextStyle`. The color/size conversions are pure string functions.
enum ForumThreadTextStyleParser {
    /// Style carried by a `<font color=... size=... style=...>` element.
    static func style(fromFontElement element: Element) throws -> ForumThreadTextStyle {
        var result = ForumThreadTextStyle()
        if let color = normalizedColorHex(try element.attr("color")) {
            result.foregroundHex = color
        }
        if let fontSize = relativeFontSize(fromHTMLSize: try element.attr("size")) {
            result.relativeFontSize = fontSize
        }
        return result.merged(with: style(fromStyleAttribute: try element.attr("style")))
    }

    /// Style carried by a CSS `style` attribute (color, background-color, font-size).
    static func style(fromStyleAttribute styleAttribute: String) -> ForumThreadTextStyle {
        let declarations = styleDeclarations(from: styleAttribute)
        return ForumThreadTextStyle(
            foregroundHex: declarations["color"].flatMap(normalizedColorHex),
            backgroundHex: declarations["background-color"].flatMap(normalizedColorHex),
            relativeFontSize: declarations["font-size"].flatMap(relativeFontSize(fromCSSFontSize:))
        )
    }

    /// Legacy HTML `size="1"..."7"` mapped to a multiplier of the base font size.
    static func relativeFontSize(fromHTMLSize rawValue: String) -> Double? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": 0.75
        case "2": 0.875
        case "3": 1
        case "4": 1.125
        case "5": 1.5
        case "6": 2
        case "7": 3
        default: nil
        }
    }

    /// CSS `font-size` in px/pt/em mapped to a multiplier of the 16px base font size.
    static func relativeFontSize(fromCSSFontSize rawValue: String) -> Double? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*(px|pt|em)$"#
        guard let match = HTMLTextExtractor.firstMatch(pattern: pattern, in: value).map({ Array($0.dropFirst()) }),
              match.count == 2,
              let number = Double(match[0]) else {
            return nil
        }
        switch match[1] {
        case "px":
            return number / 16
        case "pt":
            return (number * 4 / 3) / 16
        case "em":
            return number
        default:
            return nil
        }
    }

    /// Any CSS color spelling (#hex, #shorthand, rgb()/rgba(), named) normalized to "#RRGGBB".
    static func normalizedColorHex(_ rawValue: String) -> String? {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("#") {
            return normalizedHexDigits(String(value.dropFirst()))
        }
        if value.hasPrefix("rgb") {
            return normalizedRGBHex(value)
        }
        return namedColorHex[value]
    }

    private static func styleDeclarations(from styleAttribute: String) -> [String: String] {
        var declarations: [String: String] = [:]
        for declaration in styleAttribute.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                declarations[key] = value
            }
        }
        return declarations
    }

    private static func normalizedHexDigits(_ digits: String) -> String? {
        let valid = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard digits.unicodeScalars.allSatisfy({ valid.contains($0) }) else { return nil }
        switch digits.count {
        case 3:
            let expanded = digits.map { "\($0)\($0)" }.joined()
            return "#\(expanded.uppercased())"
        case 6:
            return "#\(digits.uppercased())"
        default:
            return nil
        }
    }

    private static func normalizedRGBHex(_ value: String) -> String? {
        let body = value
            .replacingOccurrences(of: #"^rgba?\("#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\)$"#, with: "", options: .regularExpression)
        let components = body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard components.count >= 3 else { return nil }
        let channels = components.prefix(3).compactMap(rgbChannel)
        guard channels.count == 3 else { return nil }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    private static func rgbChannel(_ rawValue: String) -> Int? {
        if rawValue.hasSuffix("%") {
            guard let value = Double(rawValue.dropLast()) else { return nil }
            return Int((min(max(value / 100, 0), 1) * 255).rounded())
        }
        guard let value = Double(rawValue) else { return nil }
        return Int(min(max(value, 0), 255).rounded())
    }

    private static let namedColorHex: [String: String] = [
        "red": "#FF0000",
        "blue": "#0000FF",
        "green": "#008000",
        "yellow": "#FFFF00",
        "black": "#000000",
        "white": "#FFFFFF",
        "grey": "#808080",
        "gray": "#808080",
        "darkgreen": "#006400",
        "darkblue": "#00008B",
        "darkred": "#8B0000",
        "darkorange": "#FF8C00",
        "darkgray": "#A9A9A9",
        "darkgrey": "#A9A9A9",
        "lightgray": "#D3D3D3",
        "lightgrey": "#D3D3D3",
        "lightblue": "#ADD8E6",
        "lightgreen": "#90EE90",
        "pink": "#FFC0CB",
        "orange": "#FFA500",
        "purple": "#800080",
        "skyblue": "#87CEEB",
        "palegreen": "#98FB98",
        "cyan": "#00FFFF",
        "magenta": "#FF00FF"
    ]
}

extension ForumThreadTextStyle {
    /// Overlay of `other` on top of this style: boolean traits are OR-ed,
    /// colors and font size take the inner (`other`) value when present.
    func merged(with other: ForumThreadTextStyle) -> ForumThreadTextStyle {
        ForumThreadTextStyle(
            isBold: isBold || other.isBold,
            isItalic: isItalic || other.isItalic,
            isUnderline: isUnderline || other.isUnderline,
            isStrikethrough: isStrikethrough || other.isStrikethrough,
            foregroundHex: other.foregroundHex ?? foregroundHex,
            backgroundHex: other.backgroundHex ?? backgroundHex,
            relativeFontSize: other.relativeFontSize ?? relativeFontSize
        )
    }
}
