import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaPagedReaderZoomableSpreadSurface: View {
    let spreadID: String
    let leftPageSurface: MangaPagedReaderSpreadPageSurface?
    let rightPageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let isZoomInteractionEnabled: Bool
    let spreadSurfaceInteraction: MangaSurfaceAttachment
    let likedPageIDs: Set<String>

    @State private var instance = UUID()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let runtime = spreadSurfaceInteraction.runtime
            let configuration = MangaInteractionConfiguration(chromeVisible: isChromeVisible,
                zoomEnabled: isZoomInteractionEnabled, allowsUnzoomedPan: false)
            let geometry = MangaSurfaceGeometry.spread(viewport: proxy.size)
            ZStack {
                pageEdgeFillStyle.color(for: colorScheme)
                HStack(spacing: 0) {
                    pageSlot(leftPageSurface)
                    pageSlot(rightPageSurface)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(runtime.transform.scale)
                .offset(runtime.transform.offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(MangaSurfaceGesture(runtime: runtime, registry: spreadSurfaceInteraction.gestures, role: .pan, instance: instance))
            .gesture(MangaSurfaceGesture(runtime: runtime, registry: spreadSurfaceInteraction.gestures, role: .pinch, instance: instance))
            .onAppear {
                runtime.mount(instance)
                runtime.configure(configuration, geometry: geometry, imageLoaded: hasLoadedImage)
            }
            .onChange(of: geometry) { _, _ in
                guard runtime.isMounted(instance) else { return }
                runtime.configure(configuration, geometry: geometry, imageLoaded: hasLoadedImage)
                spreadSurfaceInteraction.gestures.cancel()
            }
            .onChange(of: configuration) { _, _ in
                guard runtime.isMounted(instance) else { return }
                runtime.configure(configuration, geometry: geometry, imageLoaded: hasLoadedImage)
                spreadSurfaceInteraction.gestures.cancel()
            }
            .onChange(of: hasLoadedImage) { _, _ in
                guard runtime.isMounted(instance) else { return }
                runtime.configure(configuration, geometry: geometry, imageLoaded: hasLoadedImage)
            }
            .onDisappear { runtime.unmount(instance) }
        }
    }

    private var hasLoadedImage: Bool {
        [leftPageSurface, rightPageSurface].compactMap { $0 }.contains { $0.surfaceInteraction.runtime.imageLoaded }
    }

    private func pageSlot(_ surface: MangaPagedReaderSpreadPageSurface?) -> some View {
        MangaPagedReaderPageSlot(surface: surface, imageLoader: imageLoader, pageScaleMode: pageScaleMode,
            pageEdgeFillStyle: pageEdgeFillStyle, isChromeVisible: isChromeVisible, zoomEnabled: false,
            allowsUnzoomedSurfacePan: false, isPageZoomEnabled: false, likedPageIDs: likedPageIDs)
    }
}
#endif
