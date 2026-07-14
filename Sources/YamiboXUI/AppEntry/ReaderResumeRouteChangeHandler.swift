import YamiboXCore

public typealias ReaderResumeRouteChangeHandler = @MainActor @Sendable (ReaderResumeRoute) async -> Void
