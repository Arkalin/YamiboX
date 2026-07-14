enum NovelReaderVerticalViewportPositionUpdateTiming {
    enum Trigger: Equatable, Sendable {
        case textViewportSampleChanged
        case viewportGeometryChanged
    }

    enum UpdateMode: Equatable, Sendable {
        case immediate
        case deferred
    }

    static func updateMode(for trigger: Trigger) -> UpdateMode {
        switch trigger {
        case .textViewportSampleChanged:
            return .immediate
        case .viewportGeometryChanged:
            return .deferred
        }
    }
}
