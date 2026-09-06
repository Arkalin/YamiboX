import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderScaledImage: View {
    let image: UIImage
    let pageID: String
    let pageScaleMode: MangaPageScaleMode
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isSurfaceInteractionEnabled: Bool
    let isZoomInteractionEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let surfaceInteraction: MangaSurfaceAttachment
    let onLongPress: () -> Void

    @State private var instance = UUID()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let runtime = surfaceInteraction.runtime
            let transform = runtime.transform
            let layout = MangaPagedImageSurfaceLayout(imageSize: image.size, containerSize: proxy.size,
                pageScaleMode: pageScaleMode, initialHorizontalAlignment: initialHorizontalAlignment, zoomScale: transform.scale)
            let menuFrame = MangaPageLongPressHitTesting.allowedFrame(in: CGRect(origin: .zero, size: proxy.size),
                imageFrame: layout.displayedImageFrame(forUserOffset: transform.offset))
            let geometry = MangaSurfaceGeometry.image(size: image.size, viewport: proxy.size,
                fit: MangaSurfaceFit(pageScaleMode), alignment: initialHorizontalAlignment)
            let configuration = MangaInteractionConfiguration(chromeVisible: !isSurfaceInteractionEnabled,
                zoomEnabled: isZoomInteractionEnabled, allowsUnzoomedPan: allowsUnzoomedSurfacePan)

            MangaSurfaceDrawing(image: Image(uiImage: image), background: pageEdgeFillStyle.color(for: colorScheme),
                layout: layout, offset: transform.offset)
            .gesture(MangaSurfaceGesture(runtime: runtime, registry: surfaceInteraction.gestures, role: .pan, instance: instance))
            .gesture(MangaSurfaceGesture(runtime: runtime, registry: surfaceInteraction.gestures, role: .pinch, instance: instance))
            .gesture(MangaSurfaceGesture(runtime: runtime, registry: surfaceInteraction.gestures,
                role: .longPress, menuFrame: menuFrame, onMenu: onLongPress, instance: instance))
            .onAppear {
                runtime.mount(instance)
                runtime.configure(configuration, geometry: geometry, imageLoaded: true)
            }
            .onChange(of: geometry) { _, _ in
                guard runtime.isMounted(instance) else { return }
                runtime.configure(configuration, geometry: geometry, imageLoaded: true)
                surfaceInteraction.gestures.cancel()
            }
            .onChange(of: configuration) { _, _ in
                guard runtime.isMounted(instance) else { return }
                runtime.configure(configuration, geometry: geometry, imageLoaded: true)
                surfaceInteraction.gestures.cancel()
            }
            .onDisappear { runtime.unmount(instance) }
        }
    }
}
#endif
