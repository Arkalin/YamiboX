import Foundation

/// Pure color, size, and inline-style rules shared by editing and HTML adapters.
enum ForumTextStyleRules {
    /// Style carried by CSS (color, background-color, font-size, font-style).
    static func style(fromStyleAttribute styleAttribute: String) -> ForumThreadTextStyle {
        let declarations = styleDeclarations(from: styleAttribute)
        let decoration = declarations["text-decoration"] ?? declarations["text-decoration-line"] ?? ""
        let weight = declarations["font-weight"]?.lowercased() ?? ""
        return ForumThreadTextStyle(
            isBold: weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600,
            isItalic: ["italic", "oblique"].contains(declarations["font-style"]?.lowercased() ?? ""),
            isUnderline: decoration.contains("underline"),
            isStrikethrough: decoration.contains("line-through"),
            foregroundHex: declarations["color"].flatMap(normalizedColorHex),
            backgroundHex: declarations["background-color"].flatMap(normalizedColorHex),
            relativeFontSize: declarations["font-size"].flatMap(relativeFontSize(fromCSSFontSize:)),
            fontFamily: declarations["font-family"],
            baseline: declarations["vertical-align"].flatMap { value in
                switch value.lowercased() {
                case "super": 1
                case "sub": -1
                case "baseline": 0
                default: nil
                }
            }
        )
    }

    static func cssPixels(_ value: String) -> Double? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let multiplier: Double
        let number: String
        if value.hasSuffix("px") { number = String(value.dropLast(2)); multiplier = 1 }
        else if value.hasSuffix("pt") { number = String(value.dropLast(2)); multiplier = 4 / 3 }
        else if value == "0" { return 0 }
        else { return nil }
        guard let parsed = Double(number), parsed.isFinite else { return nil }
        return parsed * multiplier
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
              let number = Double(match[0]), number.isFinite, number > 0 else {
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

    /// CSS colors normalized to #RRGGBB, or #RRGGBBAA when translucent.
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
        if value == "transparent" { return "#00000000" }
        return ForumThreadCSSNamedColors.values[value]
    }

    static func styleDeclarations(from styleAttribute: String) -> [String: String] {
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
        case 3, 4:
            let expanded = digits.map { "\($0)\($0)" }.joined()
            return "#\(expanded.uppercased())"
        case 6, 8:
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
        guard value.hasSuffix(")"), components.count == (value.hasPrefix("rgba(") ? 4 : 3) else { return nil }
        let channels = components.prefix(3).compactMap(rgbChannel)
        guard channels.count == 3 else { return nil }
        let rgb = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
        guard components.count == 4 else { return rgb }
        let rawAlpha = components[3]
        guard let alpha = Double(rawAlpha.replacingOccurrences(of: "%", with: "")), alpha.isFinite else { return nil }
        let normalized = min(max(rawAlpha.hasSuffix("%") ? alpha / 100 : alpha, 0), 1)
        return normalized == 1 ? rgb : rgb + String(format: "%02X", Int((normalized * 255).rounded()))
    }

    private static func rgbChannel(_ rawValue: String) -> Int? {
        if rawValue.hasSuffix("%") {
            guard let value = Double(rawValue.dropLast()), value.isFinite else { return nil }
            return Int((min(max(value / 100, 0), 1) * 255).rounded())
        }
        guard let value = Double(rawValue), value.isFinite else { return nil }
        return Int(min(max(value, 0), 255).rounded())
    }

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
            relativeFontSize: other.relativeFontSize ?? relativeFontSize,
            fontFamily: other.fontFamily ?? fontFamily,
            baseline: other.baseline ?? baseline
        )
    }
}
