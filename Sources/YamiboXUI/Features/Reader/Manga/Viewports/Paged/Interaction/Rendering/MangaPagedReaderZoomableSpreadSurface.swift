import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderZoomableSpreadSurface: View {
    let spreadID: String
    let leftPageSurface: MangaPagedReaderSpreadPageSurface?
    let rightPageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isZoomInteractionEnabled: Bool
    let spreadSurfaceInteraction: MangaSurfaceAttachment
    let likedPageIDs: Set<String>

    var body: some View {
        GeometryReader { proxy in
            MangaNativeHostedSurface(runtime: spreadSurfaceInteraction.runtime,
                configuration: MangaInteractionConfiguration(chromeVisible: spreadSurfaceInteraction.runtime.configuration.chromeVisible,
                    zoomEnabled: isZoomInteractionEnabled, allowsUnzoomedPan: false),
                viewport: proxy.size, imageLoaded: hasLoadedImage) {
                HStack(spacing: 0) {
                    pageSlot(leftPageSurface)
                    pageSlot(rightPageSurface)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private var hasLoadedImage: Bool {
        [leftPageSurface, rightPageSurface].compactMap { $0 }.contains { $0.surfaceInteraction.runtime.imageLoaded }
    }

    private func pageSlot(_ surface: MangaPagedReaderSpreadPageSurface?) -> some View {
        MangaPagedReaderPageSlot(surface: surface, imageLoader: imageLoader, pageScaleMode: pageScaleMode,
            pageEdgeFillStyle: pageEdgeFillStyle, zoomEnabled: false,
            allowsUnzoomedSurfacePan: false, isPageZoomEnabled: false, likedPageIDs: likedPageIDs)
    }
}

private struct MangaNativeHostedSurface<Content: View>: UIViewRepresentable {
    let runtime: MangaSurfaceRuntime
    let configuration: MangaInteractionConfiguration
    let viewport: CGSize
    let imageLoaded: Bool
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var hostedView: (UIView & UIContentView)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MangaNativeSurfaceView {
        let view = MangaNativeSurfaceView()
        let hosted = UIHostingConfiguration { content() }.margins(.all, 0).makeContentView()
        context.coordinator.hostedView = hosted
        view.zoomContentView.addSubview(hosted)
        view.onBaseSizeChange = { [weak hosted] size in hosted?.frame = CGRect(origin: .zero, size: size) }
        return view
    }

    func updateUIView(_ view: MangaNativeSurfaceView, context: Context) {
        context.coordinator.hostedView?.configuration = UIHostingConfiguration { content() }.margins(.all, 0)
        view.configure(runtime: runtime, configuration: configuration,
                       geometry: .spread(viewport: viewport), imageLoaded: imageLoaded)
    }

    static func dismantleUIView(_ view: MangaNativeSurfaceView, coordinator: Coordinator) {
        view.detach()
        coordinator.hostedView = nil
    }
}
#endif
