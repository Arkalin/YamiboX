import Foundation

/// Derives the clause context stored alongside a text excerpt
/// (`LikeItem.excerptPrefix` / `excerptSuffix`) from the document text around
/// the selection.
///
/// Pure string work, so both capture (selection in hand) and the reader's
/// lazy backfill (persisted anchor re-resolved against a laid-out chapter)
/// share one definition of where a clause starts.
package enum NovelLikeExcerptContext {
    /// A highlight that starts mid-clause shows the clause's un-highlighted
    /// head, so the row reads from the beginning of the thought — clause, not
    /// sentence, keeps the head short ("大概**有一二百人吧**" rather than a
    /// full compound sentence of lead-in).
    private static let clauseDelimiters = Set("。！？…；：，、\n.!?;:,")

    /// The suffix runs to the end of the sentence, not just the clause: it
    /// exists to fill the row's single line after the highlight, and stopping
    /// at the first comma would cut the thought short of the line.
    private static let sentenceDelimiters = Set("。！？…\n")

    /// Longest stored prefix, in characters. The row shows ~20 CJK characters;
    /// a clause head longer than this would fill the line before the highlight
    /// became visible, so only the nearest run is kept — trading "starts at the
    /// exact clause boundary" for "the highlight stays on the line".
    private static let prefixCharacterLimit = 16

    /// Longest stored suffix. Generous relative to the line because the line
    /// truncates visually anyway; the cap only bounds what the row stores.
    private static let suffixCharacterLimit = 40

    /// - Parameters:
    ///   - textBefore: document text immediately before the selection, already
    ///     sliced to a bounded window.
    ///   - textAfter: document text immediately after the selection.
    package static func make(
        textBefore: String,
        textAfter: String
    ) -> (prefix: String?, suffix: String?) {
        (prefix: prefix(from: textBefore), suffix: suffix(from: textAfter))
    }

    private static func prefix(from textBefore: String) -> String? {
        let clauseHead: Substring
        if let boundary = textBefore.lastIndex(where: { clauseDelimiters.contains($0) }) {
            clauseHead = textBefore[textBefore.index(after: boundary)...]
        } else {
            clauseHead = textBefore[...]
        }
        let trimmed = clauseHead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(prefixCharacterLimit))
    }

    private static func suffix(from textAfter: String) -> String? {
        var tail = textAfter[...]
        if let boundary = tail.firstIndex(where: { sentenceDelimiters.contains($0) }) {
            // Keep the punctuation itself — "……的男子" reading better with its
            // closing 。 than stopping dead — but never a newline.
            let end = tail[boundary].isNewline ? boundary : tail.index(after: boundary)
            tail = tail[..<end]
        }
        let trimmed = String(tail.prefix(suffixCharacterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
