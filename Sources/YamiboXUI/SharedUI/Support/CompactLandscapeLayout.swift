import SwiftUI

/// Use the presented container, not device orientation: tall iPad windows
/// retain the stacked layout, while short landscape sheets gain two columns.
struct CompactLandscapeLayout {
    let isSideBySide: Bool
    let leadingWidth: CGFloat

    init(size: CGSize) {
        isSideBySide = size.height < 500 && size.width > size.height
        leadingWidth = min(360, size.width * 0.44)
    }

    var stack: AnyLayout {
        isSideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }
}
