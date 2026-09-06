import SwiftUI

/// The fixed viewport, rather than the possibly over-wide bitmap, owns layout.
struct MangaSurfaceDrawing: View {
    let image: Image
    let background: Color
    let layout: MangaPagedImageSurfaceLayout
    let offset: CGSize

    var body: some View {
        ZStack {
            background
            image.resizable()
                .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                .offset(layout.displayOffset(forUserOffset: offset))
        }
        .frame(width: layout.containerSize.width, height: layout.containerSize.height)
        .contentShape(Rectangle())
        .clipped()
    }
}
