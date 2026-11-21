import Foundation

public struct YamiboPersistenceError: LocalizedError, Sendable {
    public let context: String

    /// The original error, preserved for logs and debugging. `nil` when the
    /// failure is a validation guard with no source error to wrap.
    public let underlying: (any Error)?

    public init(context: String, underlying: (any Error)? = nil) {
        self.context = context
        self.underlying = underlying
    }

    public var errorDescription: String? {
        L10n.string("error.persistence_failed", context)
    }
}
