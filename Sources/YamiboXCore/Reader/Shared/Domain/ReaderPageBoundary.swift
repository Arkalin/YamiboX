package enum ReaderPageBoundary: Equatable, Sendable {
    case previous
    case next

    package init?(delta: Int) {
        guard delta != 0 else { return nil }
        self = delta < 0 ? .previous : .next
    }
}
