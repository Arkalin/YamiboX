import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderZoomableSpreadSurface: View {
    let leftPageSurface: MangaPagedReaderSpreadPageSurface?
    let rightPageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isDoubleTapZoomEnabled: Bool
    let spreadSurfaceInteraction: MangaSurfaceAttachment
    let likedPageIDs: Set<String>
    @Environment(\.mangaViewportHandoff) private var handoff

    var body: some View {
        GeometryReader { proxy in
            MangaNativeHostedSurface(runtime: spreadSurfaceInteraction.runtime,
                configuration: MangaInteractionConfiguration(chromeVisible: spreadSurfaceInteraction.runtime.configuration.chromeVisible,
                    doubleTapZoomEnabled: isDoubleTapZoomEnabled, allowsUnzoomedPan: false),
                viewport: proxy.size, imageLoaded: hasLoadedImage,
                pageContent: .spread(left: spreadImage(leftPageSurface), right: spreadImage(rightPageSurface)),
                handoff: handoff) {
                HStack(spacing: 0) {
                    pageSlot(leftPageSurface)
                    pageSlot(rightPageSurface)
                }
                // UIKit already sizes the hosting view to the spread. A fixed
                // SwiftUI frame can recenter inside the remaining safe area.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func spreadImage(_ surface: MangaPagedReaderSpreadPageSurface?) -> MangaNativeSurfaceView.SpreadImage? {
        surface.map { .init(pageID: $0.page.id, runtime: $0.surfaceInteraction.runtime) }
    }

    private var hasLoadedImage: Bool {
        // Read both dependencies even when the first checked slot is already loaded.
        let leftLoaded = leftPageSurface?.surfaceInteraction.runtime.imageLoaded == true
        let rightLoaded = rightPageSurface?.surfaceInteraction.runtime.imageLoaded == true
        return leftLoaded || rightLoaded
    }

    private func pageSlot(_ surface: MangaPagedReaderSpreadPageSurface?) -> some View {
        MangaPagedReaderPageSlot(surface: surface, imageLoader: imageLoader, pageScaleMode: pageScaleMode,
            pageEdgeFillStyle: pageEdgeFillStyle, zoomEnabled: false,
            allowsUnzoomedSurfacePan: false, isPageZoomEnabled: false, likedPageIDs: likedPageIDs)
    }
}

private struct MangaNativeHostedSurface<Content: View>: UIViewRepresentable {
    @Environment(\.readerRemoteInput) private var remoteInput
    @Environment(\.readerDeviceInteraction) private var deviceInteraction
    let runtime: MangaSurfaceRuntime
    let configuration: MangaInteractionConfiguration
    let viewport: CGSize
    let imageLoaded: Bool
    let pageContent: MangaNativeSurfaceView.PageContent
    let handoff: MangaViewportHandoff?
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var hostedView: (UIView & UIContentView)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var hostedContentConfiguration: some UIContentConfiguration {
        UIHostingConfiguration {
            // This nested hosting root must not inset the already-laid-out spread again.
            content()
                .environment(\.readerRemoteInput, remoteInput)
                .environment(\.readerDeviceInteraction, deviceInteraction)
                .ignoresSafeArea(.container, edges: MangaPagedLayoutPolicy.hostedPageSafeAreaEdges)
        }
        .margins(.all, 0)
    }

    func makeUIView(context: Context) -> MangaNativeSurfaceView {
        let view = MangaNativeSurfaceView()
        let hosted = hostedContentConfiguration.makeContentView()
        context.coordinator.hostedView = hosted
        view.zoomContentView.addSubview(hosted)
        view.onBaseSizeChange = { [weak hosted] size in hosted?.frame = CGRect(origin: .zero, size: size) }
        return view
    }

    func updateUIView(_ view: MangaNativeSurfaceView, context: Context) {
        context.coordinator.hostedView?.configuration = hostedContentConfiguration
        view.pageContent = pageContent
        view.handoff = handoff
        view.configure(runtime: runtime, configuration: configuration,
                       geometry: .spread(viewport: viewport), imageLoaded: imageLoaded)
    }

    static func dismantleUIView(_ view: MangaNativeSurfaceView, coordinator: Coordinator) {
        view.detach()
        coordinator.hostedView = nil
    }
}
#endif
