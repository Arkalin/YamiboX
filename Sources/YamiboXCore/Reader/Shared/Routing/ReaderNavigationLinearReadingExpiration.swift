/// The direction of a linear (page-by-page) reading step, as determined by
/// the caller from the specific navigation action taken (e.g. sign of a
/// relative-page delta, or comparing a before/after surface index).
public enum ReaderNavigationLinearReadingDirection: Equatable, Sendable {
    case forward
    case backward
}

public struct ReaderNavigationLinearReadingExpiration<PageKey: Equatable & Sendable>: Equatable, Sendable {
    public static var defaultThreshold: Int { 5 }

    public private(set) var latestPageKey: PageKey?
    public private(set) var latestDirection: ReaderNavigationLinearReadingDirection?
    public private(set) var linearPageCount: Int
    public var threshold: Int

    public init(threshold: Int = Self.defaultThreshold) {
        self.threshold = max(threshold, 1)
        latestPageKey = nil
        latestDirection = nil
        linearPageCount = 0
    }

    public var isArmed: Bool {
        latestPageKey != nil
    }

    public mutating func arm(at pageKey: PageKey) {
        latestPageKey = pageKey
        latestDirection = nil
        linearPageCount = 0
    }

    /// Records a linear reading step. A reversal in direction (e.g. paging
    /// forward, then back) restarts the streak instead of continuing it, so
    /// only reading that commits to a single direction for `threshold`
    /// distinct pages expires the nonlinear navigation history.
    @discardableResult
    public mutating func recordLinearReading(
        at pageKey: PageKey,
        direction: ReaderNavigationLinearReadingDirection
    ) -> Bool {
        guard let latestPageKey else { return false }
        guard latestPageKey != pageKey else { return false }

        self.latestPageKey = pageKey
        if latestDirection == direction {
            linearPageCount += 1
        } else {
            latestDirection = direction
            linearPageCount = 1
        }
        if linearPageCount >= threshold {
            reset()
            return true
        }
        return false
    }

    public mutating func reset() {
        latestPageKey = nil
        latestDirection = nil
        linearPageCount = 0
    }
}
