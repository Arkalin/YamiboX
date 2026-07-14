import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

enum NovelReaderViewportDisplayBlock: Identifiable {
    case text
    case image(URL)
    case footer(String)

    var id: String {
        switch self {
        case .text:
            return "text"
        case let .image(url):
            return "image:\(url.absoluteString)"
        case let .footer(text):
            return "footer:\(text)"
        }
    }
}

struct NovelReaderPagedHostingTopSafeAreaModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: .top)
    }
}

struct NovelReaderPresentationSpreadContent: View {
    let spread: NovelReaderPresentationSpread
    let surfaces: [NovelReaderSurface]
    let settings: NovelReaderAppearanceSettings
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let displayReferenceProvider: @MainActor (NovelReaderSurfaceIdentity) -> NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let onImageTap: (URL, String?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            spreadColumn(surfaceIndex: spread.leftSurfaceIndex)
            spreadColumn(surfaceIndex: spread.rightSurfaceIndex)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func spreadColumn(surfaceIndex: Int?) -> some View {
        Group {
            if let surfaceIndex {
                let surface = surfaces.first {
                    $0.presentationIndex == surfaceIndex
                }
                NovelReaderViewportSurfaceContent(
                    surface: surface,
                    displayReference: surface.flatMap { displayReferenceProvider($0.identity) },
                    selectionController: selectionController,
                    likeHighlightController: likeHighlightController,
                    likedImageAnchors: likedImageAnchors,
                    fallbackDocumentView: surface?.documentView,
                    fallbackSurfaceIndex: surfaceIndex,
                    settings: settings,
                    refererURL: refererURL,
                    offlineScope: offlineScope,
                    onImageTap: onImageTap
                )
                .padding(.horizontal, settings.horizontalPadding)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NovelReaderViewportSurfaceContent: View {
    let surface: NovelReaderSurface?
    let displayReference: NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let likedImageAnchors: Set<NovelImageLikeAnchor>
    let fallbackDocumentView: Int?
    let fallbackSurfaceIndex: Int?
    let settings: NovelReaderAppearanceSettings
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let onImageTap: (URL, String?) -> Void

    init(
        surface: NovelReaderSurface?,
        displayReference: NovelTextViewportDisplayReference? = nil,
        selectionController: NovelTextSelectionController? = nil,
        likeHighlightController: NovelLikeHighlightController? = nil,
        likedImageAnchors: Set<NovelImageLikeAnchor> = [],
        fallbackDocumentView: Int?,
        fallbackSurfaceIndex: Int?,
        settings: NovelReaderAppearanceSettings,
        refererURL: URL,
        offlineScope: YamiboImageOfflineScope?,
        onImageTap: @escaping (URL, String?) -> Void = { _, _ in }
    ) {
        self.surface = surface
        self.displayReference = displayReference
        self.selectionController = selectionController
        self.likeHighlightController = likeHighlightController
        self.likedImageAnchors = likedImageAnchors
        self.fallbackDocumentView = fallbackDocumentView
        self.fallbackSurfaceIndex = fallbackSurfaceIndex
        self.settings = settings
        self.refererURL = refererURL
        self.offlineScope = offlineScope
        self.onImageTap = onImageTap
    }

    var body: some View {
        Group {
            if centersExternalBlockInPagedMode {
                centeredViewportBlocks
            } else {
                stackedViewportBlocks
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var stackedViewportBlocks: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(
                viewportBlocks
            ) { block in
                NovelReaderViewportBlockView(
                    block: block,
                    displayReference: displayReference,
                    selectionController: selectionController,
                    likeHighlightController: likeHighlightController,
                    isLiked: isImageBlockLiked(block),
                    refererURL: refererURL,
                    offlineScope: offlineScope,
                    title: surface?.chapterTitle,
                    onImageTap: onImageTap
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var centeredViewportBlocks: some View {
        VStack(alignment: .center, spacing: 14) {
            ForEach(
                viewportBlocks
            ) { block in
                NovelReaderViewportBlockView(
                    block: block,
                    displayReference: displayReference,
                    selectionController: selectionController,
                    likeHighlightController: likeHighlightController,
                    isLiked: isImageBlockLiked(block),
                    refererURL: refererURL,
                    offlineScope: offlineScope,
                    title: surface?.chapterTitle,
                    onImageTap: onImageTap
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func isImageBlockLiked(_ block: NovelReaderViewportDisplayBlock) -> Bool {
        guard case let .image(url) = block else { return false }
        return isNovelImageLiked(url, surface: surface, likedAnchors: likedImageAnchors)
    }

    private var viewportBlocks: [NovelReaderViewportDisplayBlock] {
        Self.viewportBlocks(surface: surface)
    }

    private var centersExternalBlockInPagedMode: Bool {
        settings.readingMode == .paged && surface?.kind == .externalBlock
    }

    private var accessibilityIdentifier: String {
        let contextView = surface?.documentView ?? fallbackDocumentView ?? 1
        let surfaceIndex = surface?.presentationIndex ?? fallbackSurfaceIndex ?? 0
        return "novel-viewport-surface-\(contextView)-\(surfaceIndex)"
    }

    static func viewportBlocks(
        surface: NovelReaderSurface?
    ) -> [NovelReaderViewportDisplayBlock] {
        let externalBlockImages = surface?.externalBlocks.map {
            NovelReaderViewportDisplayBlock.image($0.url)
        } ?? []
        var blocks: [NovelReaderViewportDisplayBlock] = []
        guard let surface else {
            return externalBlockImages.isEmpty ? [.footer(L10n.string("reader.empty_content"))] : externalBlockImages
        }
        if surface.kind == .text {
            blocks.append(.text)
        }
        blocks.append(contentsOf: externalBlockImages)
        if blocks.isEmpty {
            blocks.append(.footer(L10n.string("reader.empty_content")))
        }
        return blocks
    }

}


private struct NovelReaderViewportBlockView: View {
    let block: NovelReaderViewportDisplayBlock
    let displayReference: NovelTextViewportDisplayReference?
    let selectionController: NovelTextSelectionController?
    let likeHighlightController: NovelLikeHighlightController?
    let isLiked: Bool
    let refererURL: URL
    let offlineScope: YamiboImageOfflineScope?
    let title: String?
    let onImageTap: (URL, String?) -> Void

    var body: some View {
        switch block {
        case .text:
            if let displayReference, !displayReference.isStale {
                NativeNovelTextViewportReferenceView(
                    displayReference: displayReference,
                    selectionController: selectionController,
                    likeHighlightController: likeHighlightController
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear.frame(height: 1)
            }
        case let .image(url):
            NovelReaderInlineViewportImage(
                url: url,
                refererURL: refererURL,
                offlineScope: offlineScope,
                title: title,
                isLiked: isLiked,
                onTap: onImageTap
            )
        case let .footer(text):
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        }
    }

}

#endif
