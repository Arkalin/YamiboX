import Foundation

#if os(iOS)
import UIKit

@MainActor
protocol ClipboardForumLinkPasteboardReading {
    func containsWebURLPattern() async -> Bool
    var string: String? { get }
}

extension UIPasteboard: ClipboardForumLinkPasteboardReading {
    func containsWebURLPattern() async -> Bool {
        do {
            let patterns = try await detectedPatterns(for: [
                \UIPasteboard.DetectedValues.probableWebURL,
                \UIPasteboard.DetectedValues.links
            ])
            return patterns.contains(\UIPasteboard.DetectedValues.probableWebURL)
                || patterns.contains(\UIPasteboard.DetectedValues.links)
        } catch {
            return false
        }
    }
}

@MainActor
final class ClipboardForumLinkPasteboardReader {
    private var detector: ClipboardForumLinkDetector

    init(detector: ClipboardForumLinkDetector = ClipboardForumLinkDetector()) {
        self.detector = detector
    }

    func promptURL(from pasteboard: ClipboardForumLinkPasteboardReading) async -> URL? {
        guard await pasteboard.containsWebURLPattern() else {
            detector.resetConsecutivePrompt()
            return nil
        }

        return detector.promptURL(from: pasteboard.string)
    }
}
#endif
