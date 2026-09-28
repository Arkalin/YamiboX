import Foundation

/// Completion validates the admitted context, never the finger's final direction.
struct MangaNavigationSession {
    struct Context: Equatable {
        let viewportGeneration: UInt64
        let selectionIndex: Int
        let configuration: MangaNavigationConfiguration
        let surfaceIdentity: ObjectIdentifier?
        let surfaceGeneration: UInt64?
    }

    private var context: Context?

    mutating func begin(in context: Context?) {
        self.context = context
    }

    mutating func finish(in currentContext: Context?) -> Bool {
        defer { cancel() }
        return context != nil && context == currentContext
    }

    mutating func cancel() {
        context = nil
    }
}
