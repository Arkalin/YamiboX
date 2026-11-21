#if os(iOS)
@MainActor
final class MangaSurfaceAttachment {
    let runtime: MangaSurfaceRuntime

    init(runtime: MangaSurfaceRuntime = MangaSurfaceRuntime()) { self.runtime = runtime }
}
#endif
