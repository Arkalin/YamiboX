import Foundation

/// The two string-presence idioms, defined once for the whole package.
///
/// Call sites used to carry private per-file copies whose semantics silently
/// drifted apart (some trimmed, some did not). The names encode the choice:
/// - `nilIfEmpty` when whitespace counts as content (input already normalized),
/// - `nilIfBlank` when whitespace-only input should collapse to nil.
///
/// `package` (not `internal`) so YamiboXUI shares this single definition too —
/// it used to carry four more private copies — while staying invisible outside
/// the package.
extension String {
    /// The string unchanged, or nil when it is empty.
    package var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// Whitespace-trimmed value, or nil when the result is empty.
    package var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
