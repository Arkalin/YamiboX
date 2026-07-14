public struct ReaderNavigationHistory<Anchor: Equatable & Sendable>: Equatable, Sendable {
    public static var defaultCapacity: Int { 10 }

    public private(set) var backStack: [Anchor]
    public private(set) var forwardStack: [Anchor]
    public var capacity: Int

    public init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(capacity, 1)
        backStack = []
        forwardStack = []
    }

    public var canGoBack: Bool {
        !backStack.isEmpty
    }

    public var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    public mutating func clear() {
        backStack.removeAll()
        forwardStack.removeAll()
    }

    public func peekBack() -> Anchor? {
        backStack.last
    }

    public func peekForward() -> Anchor? {
        forwardStack.last
    }

    public mutating func recordNonlinearJump(from source: Anchor, to target: Anchor) {
        guard source != target else { return }
        backStack = stack(backStack, pushing: source)
        forwardStack.removeAll()
    }

    @discardableResult
    public mutating func commitBack(from source: Anchor) -> Anchor? {
        guard let target = backStack.popLast() else { return nil }
        if source != target {
            forwardStack = stack(forwardStack, pushing: source)
        }
        return target
    }

    @discardableResult
    public mutating func commitForward(from source: Anchor) -> Anchor? {
        guard let target = forwardStack.popLast() else { return nil }
        if source != target {
            backStack = stack(backStack, pushing: source)
        }
        return target
    }

    @discardableResult
    public mutating func discardBackCandidate() -> Anchor? {
        backStack.popLast()
    }

    @discardableResult
    public mutating func discardForwardCandidate() -> Anchor? {
        forwardStack.popLast()
    }

    private func stack(_ stack: [Anchor], pushing anchor: Anchor) -> [Anchor] {
        guard stack.last != anchor else { return stack }
        var nextStack = stack
        nextStack.append(anchor)
        if nextStack.count > capacity {
            nextStack.removeFirst(nextStack.count - capacity)
        }
        return nextStack
    }
}
