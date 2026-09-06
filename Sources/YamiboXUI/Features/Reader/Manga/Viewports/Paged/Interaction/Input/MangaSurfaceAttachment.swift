#if os(iOS)
/// Binds one runtime surface to its recognizer registry without owning image state.
@MainActor
final class MangaSurfaceAttachment {
    let runtime: MangaSurfaceRuntime
    let gestures = MangaSurfaceGestureRegistry()

    init(runtime: MangaSurfaceRuntime = MangaSurfaceRuntime()) { self.runtime = runtime }
}
#endif
