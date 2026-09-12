#if os(iOS)
/// Stable surface identity shared by paging and the native image host.
@MainActor
final class MangaSurfaceAttachment {
    let runtime: MangaSurfaceRuntime

    init(runtime: MangaSurfaceRuntime = MangaSurfaceRuntime()) { self.runtime = runtime }
}
#endif
