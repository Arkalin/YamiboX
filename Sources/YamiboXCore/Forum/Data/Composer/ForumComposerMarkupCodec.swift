import Foundation

public enum ForumComposerMarkupCodec {
    public static func parse(_ source: String, format: ForumComposerFormat) -> [ForumComposerRun] {
        ForumComposerMarkupParser.parse(source, format: format)
    }
}
