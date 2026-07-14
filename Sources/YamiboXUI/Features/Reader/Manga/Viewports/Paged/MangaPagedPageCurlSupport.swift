import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

final class MangaPagedPageCurlContainerViewController: UIViewController {
    let pageViewController: UIPageViewController
    var onLayoutSubviews: (() -> Void)?

    init(pageViewController: UIPageViewController) {
        self.pageViewController = pageViewController
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
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageViewController.view)
        NSLayoutConstraint.activate([
            pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pageViewController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayoutSubviews?()
    }
}

final class MangaPagedPageCurlHostingController: UIHostingController<MangaPagedPageCurlLeafView> {
    let leaf: MangaPagedPageCurlLeaf

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
    let pageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let isPageZoomEnabled: Bool
    let likedPageIDs: Set<String>

    var body: some View {
        MangaPagedReaderPageSlot(
            surface: pageSurface,
            imageLoader: imageLoader,
            pageScaleMode: pageScaleMode,
            pageEdgeFillStyle: pageEdgeFillStyle,
            isChromeVisible: isChromeVisible,
            zoomEnabled: zoomEnabled,
            allowsUnzoomedSurfacePan: true,
            isPageZoomEnabled: isPageZoomEnabled,
            likedPageIDs: likedPageIDs
        )
        .ignoresSafeArea(
            .container,
            edges: UIDevice.current.userInterfaceIdiom == .pad ? .vertical : .bottom
        )
    }
}

/// Holds a weak reference to the private `pageCurl` filter(s) discovered by
/// `MangaPageCurlPrivateBackColor`, so repeated per-frame refreshes during a single
/// transition can skip re-walking the layer tree. The owning coordinator resets this
/// at the start of each new transition.
@MainActor
final class MangaPageCurlBackColorFilterCache {
    fileprivate var filters = NSHashTable<NSObject>.weakObjects()

    func reset() {
        filters.removeAllObjects()
    }
}

@MainActor
enum MangaPageCurlPrivateBackColor {
    private static let filtersKey = "filters"
    private static let backgroundFiltersKey = "backgroundFilters"
    private static let typeKey = "type"
    private static let pageCurlType = "pageCurl"
    private static let inputBackEnabledKey = "inputBackEnabled"
    private static let inputBackColor0Key = "inputBackColor0"
    private static let inputBackColor1Key = "inputBackColor1"

    /// The filter's identity is stable for the rest of a transition once found; only its
    /// back-color inputs need refreshing each frame. An empty cache (first frame of a
    /// transition, or the cached filter was deallocated) triggers a fresh tree walk.
    static func apply(to rootView: UIView, backColor: UIColor, cache: MangaPageCurlBackColorFilterCache) {
        let colorComponents = backColor.mangaPageCurlPrivateColorComponents
        let cachedFilters = cache.filters.allObjects
        guard cachedFilters.isEmpty else {
            for filter in cachedFilters {
                applyColorComponents(colorComponents, to: filter)
            }
            return
        }

        discoverAndApply(to: rootView.layer, colorComponents: colorComponents, cache: cache)
    }

    private static func discoverAndApply(
        to layer: CALayer,
        colorComponents: [NSNumber],
        cache: MangaPageCurlBackColorFilterCache
    ) {
        for filterKey in [filtersKey, backgroundFiltersKey] {
            guard let filters = layer.value(forKey: filterKey) as? [NSObject] else { continue }
            for filter in filters where isPageCurlFilter(filter) {
                applyColorComponents(colorComponents, to: filter)
                cache.filters.add(filter)
            }
        }

        layer.sublayers?.forEach { discoverAndApply(to: $0, colorComponents: colorComponents, cache: cache) }
    }

    private static func applyColorComponents(_ colorComponents: [NSNumber], to filter: NSObject) {
        filter.setValue(NSNumber(value: true), forKey: inputBackEnabledKey)
        filter.setValue(colorComponents, forKey: inputBackColor0Key)
        filter.setValue(colorComponents, forKey: inputBackColor1Key)
    }

    private static func isPageCurlFilter(_ filter: NSObject) -> Bool {
        if String(describing: filter) == pageCurlType {
            return true
        }
        return (filter.value(forKey: typeKey) as? String) == pageCurlType
    }
}

private extension UIColor {
    var mangaPageCurlPrivateColorComponents: [NSNumber] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { NSNumber(value: Double($0)) }
    }
}
#endif
