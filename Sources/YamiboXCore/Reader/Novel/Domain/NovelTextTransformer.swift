import Foundation

public enum NovelTextTransformer {
    public static func transform(_ text: String, mode: ReaderTranslationMode) -> String {
        switch mode {
        case .none:
            return text
        case .simplified:
            return applyTransform("Traditional-Simplified", to: text)
        case .traditional:
            return applyTransform("Simplified-Traditional", to: text)
        }
    }

    private static func applyTransform(_ transform: String, to text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        let didTransform = CFStringTransform(mutable, nil, transform as CFString, false)
        return didTransform ? (mutable as String) : text
    }
}
