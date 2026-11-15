import SwiftUI
import UIKit
import YamiboXCore

struct ReaderExternalGeometry: Equatable {
    let size: CGSize
    let insets: EdgeInsets
    let scale: CGFloat

    var valid: Bool { size.width >= 1 && size.height >= 1 }
    var supportsSpreads: Bool { size.width >= 720 && size.width > size.height }
}

extension EnvironmentValues {
    @Entry var readerExternalGeometry: ReaderExternalGeometry? = nil
}

struct ReaderExternalSurface: View {
    let display: ReaderExternalDisplayCoordinator
    let session: ReaderSession
    let navigator: ForumDestinationNavigator
    let appModel: YamiboAppModel
    let viewport: ReaderViewportLifetime
    @Environment(\.displayScale) private var scale
    @State private var windowInsets: UIEdgeInsets?

    var body: some View {
        GeometryReader { proxy in
            let insets = windowInsets.map {
                EdgeInsets(top: $0.top, leading: $0.left, bottom: $0.bottom, trailing: $0.right)
            } ?? proxy.safeAreaInsets
            let geometry = ReaderExternalGeometry(size: proxy.size, insets: insets, scale: scale)
            ZStack {
                if geometry.valid {
                    ReaderSessionContentView(
                        session: session, navigator: navigator, appModel: appModel,
                        isFullScreenRoot: true, externalViewport: viewport
                    )
                    .environment(\.readerExternalGeometry, geometry)
                    .environment(\.displayScale, geometry.scale)
                    .environment(\.readerDeviceInteraction, ReaderDeviceInteractionContext(
                        display: display, session: session, appModel: appModel
                    ))
                    ReaderExternalCursor(input: display.pointer)
                    ReaderExternalPrivacyCover(display: display, sessionID: session.id)
                }
            }
            .background(.black)
            .onChange(of: geometry, initial: true) { _, value in
                display.pointer.updateBounds(CGRect(origin: .zero, size: value.size))
            }
            .background(ReaderWindowSafeAreaInsetsProbe(insets: $windowInsets))
        }
        .ignoresSafeArea()
        .appTheme(.theme(for: appModel.appAppearanceSettings))
        .forumTheme(AppTheme.theme(for: appModel.appAppearanceSettings).forumTheme)
        .preferredColorScheme(appModel.appAppearanceSettings.darkMode.preferredColorScheme)
        .environment(\.readerToolbarStyle, appModel.readerToolbarStyle.effectiveStyle)
        .environment(\.yamiboImagePipeline, appModel.imagePipeline)
        .environment(\.forumBlacklist, appModel.appContext.blacklistWorkflow)
        .environment(\.readingHandoffAllowed, false)
        .environment(\.readerRemoteInput, display.pointer)
    }
}

private struct ReaderExternalPrivacyCover: View {
    let display: ReaderExternalDisplayCoordinator
    let sessionID: UUID

    var body: some View {
        if !display.showsReaderOnExternalDisplay || display.sessionID != sessionID {
            Color.black.ignoresSafeArea()
                .accessibilityHidden(true)
                .transaction { $0.animation = nil }
        }
    }
}

/// The mounted viewport must render before it can hand off or receive input.
struct ReaderViewportRenderAcknowledgement: ViewModifier {
    let ready: Bool
    let viewport: ReaderViewportLifetime

    func body(content: Content) -> some View {
        content.background {
            if ready {
                NovelReaderNavigationOverlayDisplayProbe(revision: 0, waitsForPresentation: false) { _ in
                    viewport.frameDidRender()
                }
                .accessibilityHidden(true)
            }
        }
    }
}
