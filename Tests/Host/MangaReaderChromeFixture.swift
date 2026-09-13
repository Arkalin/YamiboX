import Observation
import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

struct MangaReaderChromeFixture: View {
    @State private var model = MangaReaderChromeFixtureModel()

    var body: some View {
        NavigationStack {
            Button("Open Full Manga Reader") { model.open() }
                .accessibilityIdentifier("manga-reader-fixture-open")
                .navigationTitle("Manga Chrome Fixture")
        }
        .fullScreenCover(item: Binding(
            get: { model.appModel.presentedReaderSession },
            set: { if $0 == nil { model.appModel.dismissPresentedReaderSession() } }
        ), onDismiss: model.appModel.readerCoverDidDismiss) { session in
            ReaderSessionScreen(session: session, appModel: model.appModel)
                .background(alignment: .topLeading) {
                    MangaReaderChromeDiagnostics()
                        .frame(width: 1, height: 1)
                }
        }
        .task { await model.prepare() }
    }
}

@MainActor @Observable
private final class MangaReaderChromeFixtureModel {
    let context: YamiboAppContext
    let appModel: YamiboAppModel
    private let projection: MangaReaderProjection
    private var prepared = false

    init() {
        let name = "manga-reader-chrome-fixture"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: UserDefaults(suiteName: name)!),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: name)!),
            grdbRootDirectory: root, cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: name)!, clearsWebDataOnReset: false
        )
        let environment = ProcessInfo.processInfo.environment
        let pageCount = max(1, min(Int(environment["MANGA_READER_PAGE_COUNT"] ?? "8") ?? 8, 30))
        let urls = (0..<pageCount).map { URL(string: "https://manga-chrome-fixture.invalid/page-\($0).png")! }
        let images = Dictionary(uniqueKeysWithValues: urls.enumerated().map { ($0.element, Self.imageData(page: $0.offset)) })
        appModel = YamiboAppModel(appContext: context,
            imagePipeline: YamiboUIImagePipeline(core: YamiboImagePipeline(
                offlineImages: MangaReaderChromeFixtureImages(images: images))))
        projection = MangaReaderProjection(tid: "730001", chapterTitle: environment["MANGA_READER_CHAPTER_TITLE"] ?? "Manga Geometry Fixture", imageURLs: urls)
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        let environment = ProcessInfo.processInfo.environment
        let style = ReaderPagedTurnStyle(rawValue: environment["MANGA_READER_STYLE"] ?? "none") ?? .none
        let spread = environment["MANGA_READER_SPREAD"] != "0"
        try? await context.settingsStore.update {
            $0.manga = MangaReaderSettings(isImmersiveModeEnabled: environment["READER_IMMERSIVE"] == "1",
                readingMode: .paged, pagedTurnStyle: style,
                pageTurnDirection: environment["READER_RTL"] == "1" ? .rightToLeft : .leftToRight, pageScaleMode: .fitHeight,
                pageEdgeFillStyle: .black, showsTwoPagesInLandscapeOnPad: spread,
                ignoresTopSafeArea: environment["MANGA_READER_RESPECT_TOP"] != "1")
        }
        open()
    }

    func open() {
        let environment = ProcessInfo.processInfo.environment
        appModel.presentMangaReader(MangaLaunchContext(originalThreadID: "730001", chapterTID: "730001",
            displayTitle: environment["MANGA_READER_WORK_TITLE"] ?? "Manga Geometry Fixture", source: .forum,
            initialPage: Int(environment["MANGA_READER_INITIAL_PAGE"] ?? "0") ?? 0,
            directoryName: environment["MANGA_READER_WORK_TITLE"] ?? "Manga Geometry Fixture", isSmartModeEnabled: false), initialProjection: projection)
    }

    private static func imageData(page: Int) -> Data {
        let size = CGSize(width: 800, height: 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { renderer in
            for row in 0..<20 {
                let y = CGFloat(row * 50)
                let color: UIColor = row.isMultiple(of: 2)
                    ? (page.isMultiple(of: 2) ? .cyan : .yellow) : .white
                color.setFill()
                renderer.fill(CGRect(x: 0, y: y, width: 800, height: 50))
                UIColor.black.setFill()
                renderer.fill(CGRect(x: 0, y: y, width: 800, height: 2))
                ("P\(page + 1) y=\(row * 50)" as NSString).draw(
                    at: CGPoint(x: 24, y: y + 10),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.black])
            }
            UIColor.magenta.setFill()
            renderer.fill(CGRect(x: 398, y: 0, width: 4, height: 1000))
            UIColor.red.setStroke()
            renderer.cgContext.setLineWidth(8)
            renderer.cgContext.stroke(CGRect(x: 4, y: 4, width: 792, height: 992))
        }
    }
}

private struct MangaReaderChromeFixtureImages: YamiboOfflineImageDataProviding {
    let images: [URL: Data]
    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data? { images[url] }
}

private struct MangaReaderChromeDiagnostics: UIViewRepresentable {
    func makeUIView(context: Context) -> MangaReaderChromeDiagnosticsView { MangaReaderChromeDiagnosticsView() }
    func updateUIView(_ view: MangaReaderChromeDiagnosticsView, context: Context) {}
}

private final class MangaReaderChromeDiagnosticsView: UIView {
    private var timer: Timer?
    private var lastSnapshot = ""

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Manga reader geometry"
        accessibilityIdentifier = "manga-reader-fixture-geometry"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer(timeInterval: 0.1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc private func refresh() {
        guard let window else { return }
        let views = descendants(in: window)
        let surfaces = views.compactMap { $0 as? MangaNativeSurfaceView }.filter {
            $0.runtime?.imageLoaded == true && isVisible($0, in: window)
                && window.bounds.intersects($0.convert($0.bounds, to: window))
        }
        let surfaceValues: [[String: Any]] = surfaces.map { surface in
            var value: [String: Any] = [
                "frame": rect(surface.convert(surface.bounds, to: window)),
                "safeArea": insets(surface.safeAreaInsets),
                "offset": [surface.contentOffset.x, surface.contentOffset.y],
                "chrome": surface.runtime?.configuration.chromeVisible == true,
                "zoom": surface.normalizedZoomFactor
            ]
            if let image = surface.zoomContentView.subviews.first as? UIImageView {
                value["imageFrame"] = rect(image.convert(image.bounds, to: window))
            }
            return value
        }
        let collectionValues: [[String: Any]] = views.compactMap { $0 as? MangaPagedReaderCollectionView }.map {
            ["frame": rect($0.convert($0.bounds, to: window)), "safeArea": insets($0.safeAreaInsets),
             "contentOffset": [$0.contentOffset.x, $0.contentOffset.y]]
        }
        var measuredViews: [UIView] = []
        var measuredIDs: Set<ObjectIdentifier> = []
        for view in views where view is UIScrollView || view is ReaderPagedPageTurnCell || surfaces.contains(where: { $0 === view }) {
            var ancestor: UIView? = view
            while let candidate = ancestor, candidate !== window {
                if measuredIDs.insert(ObjectIdentifier(candidate)).inserted { measuredViews.append(candidate) }
                ancestor = candidate.superview
            }
        }
        let hierarchy: [[String: Any]] = measuredViews.map { view in
            var value: [String: Any] = [
                "class": String(describing: type(of: view)),
                "frame": rect(view.convert(view.bounds, to: window)),
                "bounds": rect(view.bounds), "safeArea": insets(view.safeAreaInsets)
            ]
            if let scroll = view as? UIScrollView {
                value["adjustmentBehavior"] = scroll.contentInsetAdjustmentBehavior.rawValue
                value["contentInset"] = insets(scroll.contentInset)
                value["adjustedContentInset"] = insets(scroll.adjustedContentInset)
                value["contentOffset"] = [scroll.contentOffset.x, scroll.contentOffset.y]
            }
            return value
        }
        let value: [String: Any] = [
            "window": rect(window.bounds), "windowSafeArea": insets(window.safeAreaInsets),
            "statusBarHidden": window.windowScene?.statusBarManager?.isStatusBarHidden ?? false,
            "surfaces": surfaceValues, "collections": collectionValues, "hierarchy": hierarchy
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let snapshot = String(data: data, encoding: .utf8), snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        accessibilityValue = snapshot
        print("MANGA_READER_CHROME \(snapshot)")
    }

    private func descendants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let candidate = ancestor {
            guard !candidate.isHidden, candidate.alpha > 0.01 else { return false }
            if candidate === window { return true }
            ancestor = candidate.superview
        }
        return false
    }

    private func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private func insets(_ value: UIEdgeInsets) -> [CGFloat] { [value.top, value.left, value.bottom, value.right] }
}
