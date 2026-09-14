import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

final class MangaPagedPageCurlContainerViewController: UIViewController {
    let pageViewController: UIPageViewController
    let zoomView = MangaNativeSurfaceView()
    let informationState: ReaderAttachedInformationState
    private lazy var informationHost = UIHostingController(rootView: MangaCurlZoomInformation(state: informationState))
    var onLayoutSubviews: (() -> Void)?

    init(pageViewController: UIPageViewController, informationState: ReaderAttachedInformationState = ReaderAttachedInformationState()) {
        self.pageViewController = pageViewController
        self.informationState = informationState
        super.init(nibName: nil, bundle: nil)
    }

    @MainActor @preconcurrency
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        addChild(pageViewController)
        view.addSubview(zoomView)
        zoomView.zoomContentView.addSubview(pageViewController.view)
        zoomView.onBaseSizeChange = { [weak self] size in
            self?.pageViewController.view.frame = CGRect(origin: .zero, size: size)
        }
        pageViewController.didMove(toParent: self)
        addChild(informationHost)
        informationHost.view.backgroundColor = .clear
        informationHost.view.isUserInteractionEnabled = false
        view.addSubview(informationHost.view)
        informationHost.didMove(toParent: self)
        zoomView.onInformationZoomChange = { [weak self] zooming in
            guard let self, self.informationState.usesStationaryZoomInformation != zooming else { return }
            self.informationState.usesStationaryZoomInformation = zooming
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        zoomView.frame = view.bounds
        informationHost.view.frame = view.bounds
        onLayoutSubviews?()
    }
}

private struct MangaCurlZoomInformation: View {
    let state: ReaderAttachedInformationState

    var body: some View {
        ReaderAttachedInformationView(state: state, itemIndex: state.configuration.selectedIndex, stationaryZoomCopy: true)
            .ignoresSafeArea()
    }
}

final class MangaPagedPageCurlHostingController: UIHostingController<MangaPagedPageCurlLeafView> {
    let leaf: MangaPagedPageCurlLeaf
    var onWillAppear: (() -> Void)?

    init(
        leaf: MangaPagedPageCurlLeaf,
        rootView: MangaPagedPageCurlLeafView,
        pageBackgroundColor: UIColor
    ) {
        self.leaf = leaf
        super.init(rootView: rootView)
        applyPageBackground(pageBackgroundColor)
    }

    @MainActor @preconcurrency
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onWillAppear?()
    }

    func applyPageBackground(_ pageBackgroundColor: UIColor) {
        view.backgroundColor = pageBackgroundColor
        view.isOpaque = true
    }

    func updateRootView(_ rootView: MangaPagedPageCurlLeafView, pageBackgroundColor: UIColor) {
        self.rootView = rootView
        applyPageBackground(pageBackgroundColor)
    }
}

struct MangaPagedPageCurlLeafView: View {
    let informationState: ReaderAttachedInformationState
    let informationIndex: Int
    let informationSlot: Int
    let pageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let zoomEnabled: Bool
    let isPageZoomEnabled: Bool
    let likedPageIDs: Set<String>
    var isBack: Bool = false
    var backContent: MangaPagedPageCurlBackContent?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            pageEdgeFillStyle.color(for: colorScheme)
            if isBack {
                backImage
                    .padding(.top, informationState.configuration.contentTopInset)
                    .overlay {
                        ReaderAttachedInformationView(state: informationState, itemIndex: informationIndex,
                            slot: informationSlot, isBack: true)
                    }
                    .scaleEffect(x: -1, y: 1)
                    .opacity(0.18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                front
            }
        }
        .allowsHitTesting(!isBack)
        .accessibilityHidden(isBack)
        .ignoresSafeArea(.container, edges: MangaPagedLayoutPolicy.hostedPageSafeAreaEdges)
    }

    private var backImage: some View {
        GeometryReader { proxy in
            if let backContent, let image = backContent.image {
                let frame = backContent.imageFrame(in: proxy.size)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .clipped()
    }

    private var front: some View {
        MangaPagedReaderPageSlot(
            surface: pageSurface,
            imageLoader: imageLoader,
            pageScaleMode: pageScaleMode,
            pageEdgeFillStyle: pageEdgeFillStyle,
            zoomEnabled: zoomEnabled,
            allowsUnzoomedSurfacePan: true,
            isPageZoomEnabled: isPageZoomEnabled,
            likedPageIDs: likedPageIDs
        )
        .padding(.top, informationState.configuration.contentTopInset)
        .background(.black)
        .overlay {
            ReaderAttachedInformationView(state: informationState, itemIndex: informationIndex, slot: informationSlot)
        }
    }
}

// A value snapshot avoids mounting a second native surface on the front's runtime.
struct MangaPagedPageCurlBackContent {
    let image: UIImage?
    let geometry: MangaSurfaceGeometry
    let transform: MangaSurfaceTransform

    func imageFrame(in viewport: CGSize) -> CGRect {
        guard geometry.viewport.width > 0, geometry.viewport.height > 0 else {
            return geometry.replacingNativeViewport(viewport).nativeImageFrame(transform)
        }
        let frame = geometry.nativeImageFrame(transform)
        return frame.applying(CGAffineTransform(
            scaleX: viewport.width / geometry.viewport.width,
            y: viewport.height / geometry.viewport.height
        ))
    }
}
#endif
