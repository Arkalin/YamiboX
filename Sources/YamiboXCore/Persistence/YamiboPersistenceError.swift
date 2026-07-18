import Foundation

/// Persistence-layer failure that preserves the original error chain.
///
/// Replaces `YamiboError.persistenceFailed(String)`, which flattened the
/// source error into a string (a concession to the enum's `Equatable`
/// requirement) and thereby lost the original error for logging and
/// debugging. `context` carries exactly the message the old case's payload
/// carried, so the user-visible copy is unchanged; `underlying` keeps the
/// source error intact for diagnostics.
public struct YamiboPersistenceError: LocalizedError, Sendable {
    /// The human-readable message; identical to the string the old
    /// `persistenceFailed(String)` payload carried at the same throw site.
    public let context: String

    /// The original error, preserved for logs and debugging. `nil` when the
    /// failure is a validation guard with no source error to wrap.
    public let underlying: (any Error)?

    public init(context: String, underlying: (any Error)? = nil) {
        self.context = context
        self.underlying = underlying
    }

    public var errorDescription: String? {
        // Verbatim the old `YamiboError.persistenceFailed` display: the same
        // localized wrapper ("本地数据保存失败：%@") around the same message, so
        // user-facing copy is byte-for-byte identical to before the split.
        L10n.string("error.persistence_failed", context)
    }
}

extension YamiboPersistenceError: Equatable {
    /// Equates by `context` plus `String(describing:)` of `underlying`. This
    /// is a pragmatic trade-off for test assertions: `any Error` has no
    /// general `Equatable`, and tests only need "same message, same-looking
    /// source error" to judge equality — the description comparison gives
    /// that without forcing `Equatable` bounds onto every wrapped error.
    public static func == (lhs: YamiboPersistenceError, rhs: YamiboPersistenceError) -> Bool {
        lhs.context == rhs.context
            && String(describing: lhs.underlying) == String(describing: rhs.underlying)
    }
}
