public enum AppBootstrapPhase: Equatable, Sendable {
    case loadingSession
    case loadingProfile
    case loadingSettings
    case synchronizingWebDAV
    case loadingReadingPosition
}
