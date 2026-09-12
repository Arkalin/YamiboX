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
    let isZoomInteractionEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let surfaceInteraction: MangaSurfaceAttachment
    let onLongPress: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            MangaNativeImageSurface(image: image, runtime: surfaceInteraction.runtime,
                configuration: MangaInteractionConfiguration(chromeVisible: surfaceInteraction.runtime.configuration.chromeVisible,
                    zoomEnabled: isZoomInteractionEnabled, allowsUnzoomedPan: allowsUnzoomedSurfacePan),
                geometry: .image(size: image.size, viewport: proxy.size,
                    fit: MangaSurfaceFit(pageScaleMode), alignment: initialHorizontalAlignment),
                background: pageEdgeFillStyle.uiColor(for: colorScheme), onLongPress: onLongPress)
        }
    }
}

private struct MangaNativeImageSurface: UIViewRepresentable {
    let image: UIImage
    let runtime: MangaSurfaceRuntime
    let configuration: MangaInteractionConfiguration
    let geometry: MangaSurfaceGeometry
    let background: UIColor
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> MangaNativeSurfaceView {
        let view = MangaNativeSurfaceView()
        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        view.zoomContentView.addSubview(imageView)
        view.onBaseSizeChange = { [weak imageView] size in imageView?.frame = CGRect(origin: .zero, size: size) }
        return view
    }

    func updateUIView(_ view: MangaNativeSurfaceView, context: Context) {
        let imageView = view.zoomContentView.subviews.first as? UIImageView
        if imageView?.image !== image { imageView?.image = image }
        view.backgroundColor = background
        view.onLongPress = onLongPress
        view.configure(runtime: runtime, configuration: configuration, geometry: geometry, imageLoaded: true)
    }

    static func dismantleUIView(_ view: MangaNativeSurfaceView, coordinator: ()) { view.detach() }
}
#endif
