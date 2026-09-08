public enum AppBootstrapPhase: Equatable, Sendable {
    case loadingSession
    case loadingProfile
    case loadingSettings
    case loadingFavorites
    case synchronizingWebDAV
    case loadingReadingPosition
}
