import SwiftUI
import UIKit
@testable import YamiboXUI

// A scene-backed host without application services, networking, or persisted user state.
@main
struct YamiboXTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            MangaLongPressFixture()
        }
    }
}

private struct MangaLongPressFixture: View {
    @State private var surface = MangaSurfaceAttachment()
    @State private var menuCount = 0
    private let image: UIImage

    init() {
        let width = Double(ProcessInfo.processInfo.environment["MANGA_TEST_IMAGE_WIDTH"] ?? "400") ?? 400
        let size = CGSize(width: width, height: 800)
        image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MangaPagedReaderScaledImage(
                image: image, pageID: "layout", pageScaleMode: .fitHeight,
                initialHorizontalAlignment: .left, pageEdgeFillStyle: .system,
                isSurfaceInteractionEnabled: true, isZoomInteractionEnabled: true,
                allowsUnzoomedSurfacePan: true, surfaceInteraction: surface,
                onLongPress: { menuCount += 1 }
            )
            .frame(width: 400, height: 800)

            Text(diagnostics)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black)
                .accessibilityIdentifier("manga-diagnostics")
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var diagnostics: String {
        let runtime = surface.runtime
        let values: [String: Double] = [
            "count": Double(menuCount),
            "loaded": runtime.imageLoaded ? 1 : 0,
            "viewportWidth": runtime.geometry.viewport.width,
            "viewportHeight": runtime.geometry.viewport.height,
            "menuMidX": runtime.menuFrame.midX,
            "menuWidth": runtime.menuFrame.width,
            "offsetX": runtime.transform.offset.width
        ]
        guard let data = try? JSONEncoder().encode(values) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
