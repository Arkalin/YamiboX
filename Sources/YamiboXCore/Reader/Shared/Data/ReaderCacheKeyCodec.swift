import Foundation

/// Single owner of the `tid_<t>_author_<a>_view_<v>` cache-key format shared
/// by both readers' projection stores and the novel offline cache. The two
/// sides previously kept private copies that drifted: the manga store
/// sanitized components while the novel store did not, so an id containing
/// the `_` separator produced keys the novel-side parser silently rejected.
enum ReaderCacheKeyCodec {
    struct Components: Equatable, Sendable {
        var threadID: String
        var authorID: String?
        var view: Int
    }

    static func groupKey(threadID: String, authorID: String?) -> String {
        [
            "tid", stableComponent(threadID),
            "author", authorComponent(authorID)
        ].joined(separator: "_")
    }

    static func entryKey(threadID: String, view: Int, authorID: String?) -> String {
        [
            groupKey(threadID: threadID, authorID: authorID),
            "view", String(max(1, view))
        ].joined(separator: "_")
    }

    /// Decodes an entry key. A sanitized component equals the original value
    /// only when the original needed no sanitizing, so match decoded
    /// components against re-encoded candidates instead of treating them as
    /// raw ids.
    static func components(from key: String) -> Components? {
        let parts = key.components(separatedBy: "_")
        guard parts.count == 6,
              parts[0] == "tid",
              parts[2] == "author",
              parts[4] == "view",
              let view = Int(parts[5]) else {
            return nil
        }
        return Components(
            threadID: parts[1],
            authorID: parts[3] == "all" ? nil : parts[3],
            view: max(1, view)
        )
    }

    /// Sanitizes one raw component: values made purely of key-safe characters
    /// pass through unchanged (keeping healthy numeric ids stable on disk),
    /// anything else — including the `_` separator itself — collapses to a
    /// stable FNV-1a hash so it cannot corrupt the key or defeat the parser.
    static func stableComponent(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "empty" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        if normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return normalized
        }
        return stableIdentifier(for: normalized)
    }

    private static func authorComponent(_ authorID: String?) -> String {
        guard let authorID, !authorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "all"
        }
        return stableComponent(authorID)
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
