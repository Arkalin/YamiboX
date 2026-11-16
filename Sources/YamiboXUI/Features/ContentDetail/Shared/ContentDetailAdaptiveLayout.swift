import SwiftUI

struct ContentDetailAdaptiveLayout<Header: View, Directory: View>: View {
    @Environment(\.forumTheme) private var theme
    @State private var headerHeight: CGFloat?
    @ViewBuilder let header: (_ isSideBySide: Bool) -> Header
    @ViewBuilder let directory: (_ isSideBySide: Bool) -> Directory

    var body: some View {
        GeometryReader { proxy in
            let layout = CompactLandscapeLayout(size: proxy.size)
            layout.stack {
                // Keep both subtrees mounted across rotation so open metadata,
                // expanded chapters and directory scroll state survive.
                ScrollView {
                    header(layout.isSideBySide)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                .scrollDisabled(!layout.isSideBySide)
                .frame(width: layout.isSideBySide ? layout.leadingWidth : nil,
                       height: layout.isSideBySide ? proxy.size.height : headerHeight)
                .background(theme.surface)
                .overlay(alignment: .trailing) {
                    if layout.isSideBySide {
                        theme.divider.frame(width: 0.5).allowsHitTesting(false)
                    }
                }

                directory(layout.isSideBySide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
