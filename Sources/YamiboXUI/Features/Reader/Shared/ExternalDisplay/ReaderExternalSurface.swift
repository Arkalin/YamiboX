import SwiftUI
import UIKit
import YamiboXCore

extension EnvironmentValues {
    @Entry var readerExternalGeometry: ReaderViewportGeometry? = nil
    @Entry var readerExternalMenuPresented = false
    @Entry var readerProgressPreviewViewport: ReaderViewportLifetime? = nil
}

enum ReaderExternalProgressPreview {
    case novel(ReaderProgressScrubPreview, backgroundStyle: ReaderBackgroundStyle)
    case manga(ReaderProgressScrubPreview, page: MangaReaderPageProjection?, imageLoader: MangaReaderPageImageLoader?)
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
            let geometry = ReaderViewportGeometry(size: proxy.size, insets: insets, scale: scale)
            let measuredGeometry = windowInsets != nil && geometry.valid ? geometry : nil
            ZStack {
                if measuredGeometry != nil {
                    ReaderSessionContentView(
                        session: session, navigator: navigator, appModel: appModel,
                        isFullScreenRoot: true, externalViewport: viewport
                    )
                    .environment(\.readerExternalGeometry, geometry)
                    .environment(\.readerExternalMenuPresented, display.isShowingDeviceMenu(for: session))
                    .environment(\.displayScale, geometry.scale)
                    .environment(\.readerDeviceInteraction, ReaderDeviceInteractionContext(
                        display: display, session: session, appModel: appModel
                    ))
                    ReaderExternalCursor(input: display.pointer)
                    ReaderExternalProgressPreviewOverlay(display: display, session: session, viewport: viewport)
                    ReaderExternalPrivacyCover(display: display, sessionID: session.id)
                }
            }
            .background(.black)
            .onChange(of: geometry, initial: true) { _, value in
                display.pointer.updateBounds(CGRect(origin: .zero, size: value.size))
            }
            .onChange(of: measuredGeometry, initial: true) { _, value in
                session.reportNovelViewportGeometry(value, for: viewport)
            }
            .background(ReaderWindowSafeAreaInsetsProbe(insets: $windowInsets))
        }
        .ignoresSafeArea()
        .appTheme(.theme(for: appModel.appAppearanceSettings))
        .forumTheme(AppTheme.theme(for: appModel.appAppearanceSettings).forumTheme)
        .environment(\.readerToolbarStyle, appModel.readerToolbarStyle.effectiveStyle)
        .environment(\.yamiboImagePipeline, appModel.imagePipeline)
        .environment(\.forumBlacklist, appModel.appContext.blacklistWorkflow)
        .environment(\.readingHandoffAllowed, false)
        .environment(\.readerRemoteInput, display.pointer)
    }
}

private struct ReaderExternalProgressPreviewOverlay: View {
    let display: ReaderExternalDisplayCoordinator
    let session: ReaderSession
    let viewport: ReaderViewportLifetime

    var body: some View {
        if display.isShowingDeviceMenu(for: session), let preview = viewport.deviceMenuProgressPreview {
            Group {
                switch preview {
                case let .novel(progress, backgroundStyle):
                    ReaderVerticalProgressPreviewCapsule(preview: progress)
                        .modifier(NovelReaderToolbarColors(backgroundStyle: backgroundStyle))
                case let .manga(progress, page, imageLoader):
                    MangaReaderProgressImagePreview(preview: progress, page: page, imageLoader: imageLoader)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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

struct ReaderViewportRenderAcknowledgement: ViewModifier {
    let ready: Bool
    let viewport: ReaderViewportLifetime
    var revision: UInt64 = 0
    var isFrameCurrent: (UInt64) -> Bool = { _ in true }

    func body(content: Content) -> some View {
        content.background {
            if ready {
                NovelReaderNavigationOverlayDisplayProbe(revision: revision, waitsForPresentation: false) { renderedRevision in
                    guard isFrameCurrent(renderedRevision) else { return }
                    viewport.frameDidRender()
                }
                .onAppear { viewport.tracePreparationStage("position-restored") }
                .accessibilityHidden(true)
            }
        }
    }
}
