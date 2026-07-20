import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import YamiboXCore

#if os(iOS)
import UIKit

struct ImageBrowserItem: Identifiable {
    let id: String
    let source: YamiboImageSource
    let title: String
    /// Optional local-bytes-first loader (e.g. Like Library's user-retained
    /// image store). The page view tries this before falling back to the
    /// network image pipeline. Existing call sites omit it and behave
    /// exactly as before.
    let localDataProvider: (@Sendable () async -> Data?)?

    init(
        id: String,
        source: YamiboImageSource,
        title: String,
        localDataProvider: (@Sendable () async -> Data?)? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.localDataProvider = localDataProvider
    }
}

extension ImageBrowserItem: Equatable {
    static func == (lhs: ImageBrowserItem, rhs: ImageBrowserItem) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source && lhs.title == rhs.title
    }
}

enum ImageBrowserMode: Equatable {
    case single
    case multiple
}

struct ImageBrowserView: View {
    let items: [ImageBrowserItem]
    let mode: ImageBrowserMode
    let presentation: ImageBrowserPresentationStyle
    let coverActionsProvider: ImageBrowserCoverActionsProvider?
    let onJumpToOriginal: (() -> Void)?
    let onDismiss: () -> Void

    @State private var selectedItemID: String
    @State private var isChromeVisible = true
    @State private var swipeDismissProgress: CGFloat = 0
    @State private var isSwipeDismissCommitted = false
    @State private var feedback: ImageBrowserFeedback?
    @State private var transientMessage: String?
    @State private var isPreparingAction = false
    @State private var coverActions: [ImageBrowserCoverAction] = []

    init(
        items: [ImageBrowserItem],
        initialItemID: String?,
        mode: ImageBrowserMode,
        presentation: ImageBrowserPresentationStyle = .fade,
        coverActionsProvider: ImageBrowserCoverActionsProvider? = nil,
        onJumpToOriginal: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.mode = mode
        self.presentation = presentation
        self.coverActionsProvider = coverActionsProvider
        self.onJumpToOriginal = onJumpToOriginal
        self.onDismiss = onDismiss
        _selectedItemID = State(initialValue: Self.initialSelection(in: items, initialItemID: initialItemID))
    }

    var body: some View {
        switch presentation {
        case .fade:
            core.modalTransitionStyle(.crossDissolve)
        case let .zoom(namespace):
            core.navigationTransition(.zoom(sourceID: selectedItemID, in: namespace))
        }
    }

    private var core: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            ImageBrowserContentView(
                items: items,
                mode: mode,
                dismissesViaSystemZoomTransition: dismissesViaSystemZoomTransition,
                selectedItemID: $selectedItemID,
                onSingleTap: toggleChrome,
                onSwipeDownProgressChange: { progress in
                    swipeDismissProgress = progress
                },
                onSwipeDownCommit: beginSwipeDownDismissCommit,
                onSwipeDownDismiss: commitSwipeDownDismiss
            )
            .ignoresSafeArea()

            ImageBrowserToolbar(
                title: currentItem?.title ?? "",
                pagePosition: pagePosition,
                isChromeVisible: isChromeVisible,
                canPerformImageAction: currentItem != nil && !isPreparingAction,
                isPreparingAction: isPreparingAction,
                swipeDismissProgress: swipeDismissProgress,
                isSwipeDismissCommitted: isSwipeDismissCommitted,
                copyImage: {
                    Task {
                        await copyImage()
                    }
                },
                shareable: currentShareable,
                saveImage: {
                    Task {
                        await saveImage()
                    }
                },
                coverActions: coverActions,
                performCoverAction: { action in
                    Task {
                        await performCoverAction(action)
                    }
                },
                onJumpToOriginal: onJumpToOriginal,
                onDismiss: onDismiss
            )
        }
        .statusBarHidden(!isChromeVisible)
        .persistentSystemOverlays(isChromeVisible ? .automatic : .hidden)
        .presentationBackground(.clear)
        .accessibilityAction(.escape) {
            onDismiss()
        }
        .task {
            await reloadCoverActions()
        }
        .alert(
            feedback?.title ?? "",
            isPresented: isFeedbackPresented,
            presenting: feedback
        ) { feedback in
            if feedback.offersOpenSettings {
                Button(L10n.string("favorites.updates.notifications_open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(L10n.string("common.cancel"), role: .cancel) {}
            } else {
                Button(L10n.string("common.done"), role: .cancel) {}
            }
        } message: { feedback in
            Text(feedback.message)
        }
        .transientMessage(transientMessage) {
            transientMessage = nil
        }
        .accessibilityIdentifier("reader-image-browser")
    }

    private var currentItem: ImageBrowserItem? {
        items.first { $0.id == selectedItemID } ?? items.first
    }

    private var pagePosition: (index: Int, count: Int)? {
        guard mode == .multiple, items.count > 1,
              let index = items.firstIndex(where: { $0.id == selectedItemID }) else {
            return nil
        }
        return (index + 1, items.count)
    }

    private var dismissesViaSystemZoomTransition: Bool {
        if case .zoom = presentation { return true }
        return false
    }

    /// Keeps a faint dim until the swipe commits so the underlying screen
    /// shows through progressively during the drag, Photos-style.
    private var backgroundOpacity: Double {
        guard !isSwipeDismissCommitted else { return 0 }
        return 1 - Double(min(max(swipeDismissProgress, 0), 1)) * 0.9
    }

    private var currentShareable: ImageBrowserShareableImage? {
        guard let currentItem else { return nil }
        return ImageBrowserShareableImage(
            source: currentItem.source,
            fileExtension: preferredImageExtension(for: currentItem),
            title: currentItem.title
        )
    }

    private var isFeedbackPresented: Binding<Bool> {
        Binding(
            get: { feedback != nil },
            set: { isPresented in
                if !isPresented {
                    feedback = nil
                }
            }
        )
    }

    private static func initialSelection(in items: [ImageBrowserItem], initialItemID: String?) -> String {
        if let initialItemID,
           items.contains(where: { $0.id == initialItemID }) {
            return initialItemID
        }
        return items.first?.id ?? ""
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isChromeVisible.toggle()
        }
    }

    private func copyImage() async {
        await performImageAction { item in
            let data = try await imageData(for: item)
            guard let image = UIImage(data: data) else {
                throw ImageBrowserActionError.invalidImageData
            }
            UIPasteboard.general.image = image
            transientMessage = L10n.string("image.copy_success_message")
        }
    }

    private func saveImage() async {
        await performImageAction { item in
            let data = try await imageData(for: item)
            let saver = MangaImagePhotoSaver()
            try await saver.saveImageData(data)
            transientMessage = L10n.string("image.save_success_message")
        }
    }

    private func reloadCoverActions() async {
        guard let coverActionsProvider else { return }
        coverActions = await coverActionsProvider()
    }

    private func performCoverAction(_ coverAction: ImageBrowserCoverAction) async {
        await performImageAction { item in
            guard let message = try await coverAction.perform(item.source) else {
                throw ImageBrowserActionError.invalidImageData
            }
            transientMessage = message
        }
        await reloadCoverActions()
    }

    private func performImageAction(_ action: @escaping (ImageBrowserItem) async throws -> Void) async {
        guard !isPreparingAction, let currentItem else { return }
        isPreparingAction = true
        defer {
            isPreparingAction = false
        }
        do {
            try await action(currentItem)
        } catch MangaImagePhotoSaveError.authorizationDenied {
            feedback = .photoPermissionDenied()
        } catch {
            YamiboLog.reader.error("Image browser action failed for item \(currentItem.id): \(error)")
            feedback = .failure(message: L10n.string("image.action_failed"))
        }
    }

    private func imageData(for item: ImageBrowserItem) async throws -> Data {
        try await YamiboImagePipeline.shared.data(for: item.source)
    }

    private func preferredImageExtension(for item: ImageBrowserItem) -> String {
        let ext = item.source.url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty, ext.count <= 8 else { return "jpg" }
        return ext
    }

    private func beginSwipeDownDismissCommit() {
        guard !isSwipeDismissCommitted else { return }
        // Ease *out*: the dim releases immediately on commit instead of
        // hesitating the way an ease-in curve does.
        withAnimation(.easeOut(duration: 0.18)) {
            isSwipeDismissCommitted = true
            swipeDismissProgress = 1
        }
    }

    private func commitSwipeDownDismiss() {
        isSwipeDismissCommitted = true
        onDismiss()
    }
}

private struct ImageBrowserContentView: View {
    let items: [ImageBrowserItem]
    let mode: ImageBrowserMode
    let dismissesViaSystemZoomTransition: Bool
    @Binding var selectedItemID: String
    let onSingleTap: () -> Void
    let onSwipeDownProgressChange: (CGFloat) -> Void
    let onSwipeDownCommit: () -> Void
    let onSwipeDownDismiss: () -> Void

    var body: some View {
        if mode == .multiple, items.count > 1 {
            // Page position lives in the toolbar ("N / M"): with dozens of
            // forum images the page-dot indicator would overflow the screen.
            let selectedIndex = items.firstIndex { $0.id == selectedItemID } ?? 0
            TabView(selection: $selectedItemID) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    pageView(for: item, pageDistance: abs(index - selectedIndex))
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        } else if let item = items.first {
            pageView(for: item, pageDistance: 0)
        } else {
            ImageBrowserFailureView(retry: nil)
        }
    }

    private func pageView(for item: ImageBrowserItem, pageDistance: Int) -> some View {
        ImageBrowserPageView(
            item: item,
            pageDistance: pageDistance,
            dismissesViaSystemZoomTransition: dismissesViaSystemZoomTransition,
            dismissRecognitionDistance: dismissRecognitionDistance,
            onSingleTap: onSingleTap,
            onSwipeDownProgressChange: onSwipeDownProgressChange,
            onSwipeDownCommit: onSwipeDownCommit,
            onSwipeDownDismiss: onSwipeDownDismiss
        )
    }

    /// The 20pt recognition dead zone only exists to lose the race to the
    /// pager's pan; without a pager it is pure latency.
    private var dismissRecognitionDistance: CGFloat {
        mode == .multiple && items.count > 1
            ? ImageBrowserSwipeDismissGesture.minimumRecognitionDistance
            : ImageBrowserSwipeDismissGesture.singleImageRecognitionDistance
    }
}

private struct ImageBrowserPageView: View {
    let item: ImageBrowserItem
    /// Pages away from the current selection (0 = the visible page); drives
    /// windowed loading, since `.page` `TabView` builds every page up front.
    let pageDistance: Int
    let dismissesViaSystemZoomTransition: Bool
    let dismissRecognitionDistance: CGFloat
    let onSingleTap: () -> Void
    let onSwipeDownProgressChange: (CGFloat) -> Void
    let onSwipeDownCommit: () -> Void
    let onSwipeDownDismiss: () -> Void

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                ImageBrowserZoomableImagePage(
                    image: image,
                    title: item.title,
                    dismissesViaSystemZoomTransition: dismissesViaSystemZoomTransition,
                    dismissRecognitionDistance: dismissRecognitionDistance,
                    onSingleTap: onSingleTap,
                    onSwipeDownProgressChange: onSwipeDownProgressChange,
                    onSwipeDownCommit: onSwipeDownCommit,
                    onSwipeDownDismiss: onSwipeDownDismiss
                )
            } else if didFail {
                ImageBrowserFailureView {
                    didFail = false
                    attempt += 1
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSingleTap)
            } else {
                ProgressView(L10n.string("image.loading"))
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSingleTap)
            }
        }
        .task(id: "\(item.source.cacheKey)#\(attempt)#\(isWithinLoadWindow)") {
            await load()
        }
        .onChange(of: pageDistance) { _, _ in
            if !isWithinKeepWindow {
                image = nil
            }
        }
    }

    /// Only pages near the selection load — without the window, a dozens-of-
    /// images forum gallery would download and decode everything the moment
    /// the browser opens.
    private var isWithinLoadWindow: Bool { pageDistance <= 2 }

    /// Loaded pages slightly beyond the load window keep their image so quick
    /// back-and-forth flips don't thrash; farther ones release it and reload
    /// from the pipeline cache on revisit.
    private var isWithinKeepWindow: Bool { pageDistance <= 4 }

    private func load() async {
        guard isWithinLoadWindow, image == nil else { return }
        if let localDataProvider = item.localDataProvider,
           let localData = await localDataProvider(),
           let localImage = UIImage(data: localData) {
            image = localImage
            return
        }
        do {
            image = try await YamiboUIImagePipeline.shared.image(for: item.source)
        } catch {
            // Leaving the load window cancels the task mid-flight; that is
            // routine paging, not a failure the retry UI should surface.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            YamiboLog.reader.warning("Failed to load image for browser item \(item.id): \(error)")
            didFail = true
        }
    }
}

/// One zoomable page: the `UIScrollView` container handles zooming and
/// panning, while the swipe-down-to-dismiss drag stays a SwiftUI gesture on
/// top, active only at minimum zoom (see `swipeDismissGestureMask`).
private struct ImageBrowserZoomableImagePage: View {
    let image: UIImage
    let title: String
    let dismissesViaSystemZoomTransition: Bool
    let dismissRecognitionDistance: CGFloat
    let onSingleTap: () -> Void
    let onSwipeDownProgressChange: (CGFloat) -> Void
    let onSwipeDownCommit: () -> Void
    let onSwipeDownDismiss: () -> Void

    /// Live swipe-dismiss drag. `engagementOrigin` records the raw
    /// translation at the moment the vertical-dominance gate passed;
    /// `translation` is measured from there, so the image starts following
    /// from directly under the finger instead of jumping by the recognition
    /// distance the moment the gesture engages.
    private struct SwipeDismissDrag: Equatable {
        var engagementOrigin: CGSize?
        var translation: CGSize = .zero
    }

    @State private var zoomProxy = ImageBrowserZoomProxy()
    @State private var zoomFactor: CGFloat = 1
    @State private var isSwipeDismissCommitted = false
    @State private var committedTranslation: CGSize = .zero
    @State private var exitOffset: CGFloat = 0
    @State private var imageOpacity: CGFloat = 1
    /// Snapshot of the last `updating` tick for `onEnded`, which runs after
    /// `@GestureState` has already reset and so cannot read `drag` itself.
    @State private var lastDrag = SwipeDismissDrag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `@GestureState` (rather than `@State`) so a system-cancelled drag —
    /// incoming call, notification-center grab — springs back automatically
    /// instead of wedging the image at a stale offset.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.22, dampingFraction: 0.86)))
    private var drag = SwipeDismissDrag()

    var body: some View {
        GeometryReader { geometry in
            ImageBrowserZoomableScrollView(
                image: image,
                proxy: zoomProxy,
                onSingleTap: onSingleTap,
                onZoomFactorChange: { zoomFactor = $0 }
            )
            .scaleEffect(reduceMotion ? 1 : ImageBrowserSwipeDismissGesture.imageScale(for: swipeProgress))
            .offset(x: swipeOffset.width, y: swipeOffset.height)
            .opacity(imageOpacity)
            .simultaneousGesture(
                swipeDismissGesture(containerSize: geometry.size),
                including: swipeDismissGestureMask
            )
        }
        .onChange(of: swipeProgress) { _, newValue in
            onSwipeDownProgressChange(newValue)
        }
        .onDisappear {
            zoomProxy.resetZoom(animated: false)
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isImage)
        .accessibilityAction {
            onSingleTap()
        }
        .accessibilityZoomAction { action in
            zoomProxy.stepZoom(zoomIn: action.direction == .zoomIn)
        }
    }

    private var isZoomedIn: Bool {
        ImageBrowserZoomMath.isEngagedZoom(factor: zoomFactor)
    }

    private var swipeOffset: CGSize {
        isSwipeDismissCommitted
            ? CGSize(width: committedTranslation.width, height: committedTranslation.height + exitOffset)
            : drag.translation
    }

    private var swipeProgress: CGFloat {
        isSwipeDismissCommitted ? 1 : ImageBrowserSwipeDismissGesture.progress(for: drag.translation.height)
    }

    /// Detaches the dismiss drag entirely while zoomed in, so it never
    /// competes with the scroll view's own pan for the same touch; at minimum
    /// zoom the scroll view has nothing to scroll and the drag takes over.
    private var swipeDismissGestureMask: GestureMask {
        isZoomedIn || isSwipeDismissCommitted ? .subviews : .all
    }

    private func swipeDismissGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: dismissRecognitionDistance)
            .updating($drag) { value, state, _ in
                // Mirror every tick — including non-engaged ones — so
                // `onEnded` never acts on a stale snapshot left behind by an
                // earlier, system-cancelled drag.
                defer { lastDrag = state }
                guard !isSwipeDismissCommitted, !isZoomedIn else { return }
                // Gate on downward intent only until the drag engages; once
                // the image is following the finger, losing momentary
                // vertical dominance must not snap it back to zero mid-drag.
                if state.engagementOrigin == nil {
                    guard ImageBrowserSwipeDismissGesture.canBegin(
                        translation: CGPoint(x: value.translation.width, y: value.translation.height),
                        zoomScale: zoomFactor,
                        minimumZoomScale: 1
                    ) else {
                        return
                    }
                    state.engagementOrigin = value.translation
                }
                guard let origin = state.engagementOrigin else { return }
                // Track both axes so the image stays under the finger during
                // a diagonal drag, Photos-style; progress/commit still key
                // off the vertical component alone.
                state.translation = CGSize(
                    width: value.translation.width - origin.width,
                    height: max(value.translation.height - origin.height, 0)
                )
            }
            .onEnded { value in
                let finalDrag = lastDrag
                lastDrag = SwipeDismissDrag()
                guard !isSwipeDismissCommitted, !isZoomedIn, finalDrag.engagementOrigin != nil else { return }
                let translation = CGPoint(x: finalDrag.translation.width, y: finalDrag.translation.height)
                let velocity = CGPoint(x: value.velocity.width, y: value.velocity.height)
                guard ImageBrowserSwipeDismissGesture.shouldDismiss(
                    translation: translation,
                    velocity: velocity,
                    zoomScale: zoomFactor,
                    minimumZoomScale: 1
                ) else {
                    return
                }
                commitSwipeDismiss(translation: translation, velocity: velocity, containerSize: containerSize)
            }
    }

    private func commitSwipeDismiss(translation: CGPoint, velocity: CGPoint, containerSize: CGSize) {
        isSwipeDismissCommitted = true
        committedTranslation = CGSize(width: translation.x, height: max(translation.y, 0))
        onSwipeDownCommit()

        // Under the system zoom transition the dismiss animation itself flies
        // the page back into its thumbnail; animating our own exit first
        // would play two animations back to back.
        guard !dismissesViaSystemZoomTransition else {
            onSwipeDownDismiss()
            return
        }

        // Reduce Motion: no fly-away travel, dismiss as a plain cross-fade.
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2), completionCriteria: .logicallyComplete) {
                imageOpacity = 0
            } completion: {
                onSwipeDownDismiss()
            }
            return
        }

        let imageHeight = ImageContentGeometry.aspectFitFrame(
            imageSize: image.size,
            containerSize: containerSize
        ).height
        let exitDistance = max(
            containerSize.height - committedTranslation.height + imageHeight * 0.35,
            containerSize.height * 0.45
        )
        // Continue the exit at the finger's release speed instead of
        // restarting from zero on a fixed curve — the seam between drag and
        // animation disappears.
        let initialVelocity = GesturePhysics.relativeVelocity(velocity.y, from: 0, to: exitDistance)
        withAnimation(.easeOut(duration: 0.25)) {
            imageOpacity = 0
        }
        withAnimation(
            .gestureMomentum(initialVelocity: initialVelocity),
            completionCriteria: .logicallyComplete
        ) {
            exitOffset = exitDistance
        } completion: {
            onSwipeDownDismiss()
        }
    }
}

private struct ImageBrowserFailureView: View {
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Label(L10n.string("image.load_failed"), systemImage: "photo")
                .foregroundStyle(.white.opacity(0.8))

            if let retry {
                Button(action: retry) {
                    Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(24)
    }
}

private struct ImageBrowserToolbar: View {
    let title: String
    let pagePosition: (index: Int, count: Int)?
    let isChromeVisible: Bool
    let canPerformImageAction: Bool
    let isPreparingAction: Bool
    let swipeDismissProgress: CGFloat
    let isSwipeDismissCommitted: Bool
    let copyImage: () -> Void
    let shareable: ImageBrowserShareableImage?
    let saveImage: () -> Void
    let coverActions: [ImageBrowserCoverAction]
    let performCoverAction: (ImageBrowserCoverAction) -> Void
    let onJumpToOriginal: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let pagePosition {
                        Text(verbatim: "\(pagePosition.index) / \(pagePosition.count)")
                            .font(.footnote.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .accessibilityLabel(
                                L10n.string("image.position_accessibility", pagePosition.index, pagePosition.count)
                            )
                    }
                }

                Spacer(minLength: 12)

                Menu {
                    Button(action: copyImage) {
                        Label(L10n.string("image.copy"), systemImage: "doc.on.doc")
                    }

                    if let shareable {
                        ShareLink(item: shareable, preview: SharePreview(shareable.title)) {
                            Label(L10n.string("common.share"), systemImage: "square.and.arrow.up")
                        }
                    }

                    Button(action: saveImage) {
                        Label(L10n.string("image.save_to_photos"), systemImage: "square.and.arrow.down")
                    }

                    if !coverActions.isEmpty {
                        Divider()
                        ForEach(coverActions) { action in
                            Button {
                                performCoverAction(action)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }

                    if let onJumpToOriginal {
                        Divider()
                        Button(action: onJumpToOriginal) {
                            Label(L10n.string("likes.jump_to_original"), systemImage: "book.closed")
                        }
                    }
                } label: {
                    Group {
                        if isPreparingAction {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "ellipsis")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.58), in: Circle())
                }
                .disabled(!canPerformImageAction)
                .accessibilityLabel(L10n.string("common.more"))

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .accessibilityLabel(L10n.string("common.close"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.62), .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )

            Spacer(minLength: 0)
        }
        .opacity(effectiveOpacity)
        .allowsHitTesting(isChromeVisible && !isSwipeDismissCommitted)
        .accessibilityHidden(!isChromeVisible)
    }

    private var effectiveOpacity: Double {
        guard isChromeVisible else { return 0 }
        return 1 - min(swipeDismissProgress * 1.4, 1)
    }
}

private enum ImageBrowserActionError: Error {
    case invalidImageData
}

private struct ImageBrowserFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var offersOpenSettings = false

    static func failure(message: String) -> ImageBrowserFeedback {
        ImageBrowserFeedback(title: L10n.string("common.operation_failed"), message: message)
    }

    static func photoPermissionDenied() -> ImageBrowserFeedback {
        ImageBrowserFeedback(
            title: L10n.string("image.save_photo_permission_denied_title"),
            message: L10n.string("image.save_photo_permission_denied"),
            offersOpenSettings: true
        )
    }
}

/// Lazily materializes the shared image when the user commits to sharing:
/// ShareLink drives the export, so no temp file or spinner state is needed
/// up front. The exported file lands in the system temporary directory and
/// is reclaimed by the OS.
private struct ImageBrowserShareableImage: Transferable {
    let source: YamiboImageSource
    let fileExtension: String
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { shareable in
            let data = try await YamiboImagePipeline.shared.data(for: shareable.source)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(shareable.fileExtension)
            try data.write(to: fileURL, options: .atomic)
            return SentTransferredFile(fileURL)
        }
    }
}
#endif
