import Foundation

/// Adapts external BBCode/HTML into the editing model. HTML parsing stays in Data.
public enum ForumComposerMarkupCodec {
    public static func parse(_ source: String, format: ForumComposerFormat) -> [ForumComposerRun] {
        ForumComposerMarkupParser.parse(source, format: format)
    }
}
