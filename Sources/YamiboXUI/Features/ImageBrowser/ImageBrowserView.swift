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
    let caption: String?
    let localDataProvider: (@Sendable () async -> Data?)?

    init(
        id: String,
        source: YamiboImageSource,
        title: String,
        caption: String? = nil,
        localDataProvider: (@Sendable () async -> Data?)? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.caption = caption
        self.localDataProvider = localDataProvider
    }
}

extension ImageBrowserItem: Equatable {
    static func == (lhs: ImageBrowserItem, rhs: ImageBrowserItem) -> Bool {
        lhs.id == rhs.id
            && lhs.source == rhs.source
            && lhs.title == rhs.title
            && lhs.caption == rhs.caption
    }
}

enum ImageBrowserMode: Equatable {
    case single
    case multiple
}

struct ImageBrowserView: View {
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    let items: [ImageBrowserItem]
    let mode: ImageBrowserMode
    let presentation: ImageBrowserPresentationStyle
    let coverActionsProvider: ImageBrowserCoverActionsProvider?
    let onEditNote: ((ImageBrowserItem) -> Void)?
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
        onEditNote: ((ImageBrowserItem) -> Void)? = nil,
        onJumpToOriginal: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.mode = mode
        self.presentation = presentation
        self.coverActionsProvider = coverActionsProvider
        self.onEditNote = onEditNote
        self.onJumpToOriginal = onJumpToOriginal
        self.onDismiss = onDismiss
        _selectedItemID = State(initialValue: Self.initialSelection(in: items, initialItemID: initialItemID))
    }

    var body: some View {
        switch presentation {
        case .fade:
            core
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
            .contextMenu {
                imageActionsMenu
            }

            ImageBrowserToolbar(
                title: currentItem?.title ?? "",
                caption: currentItem?.caption,
                pagePosition: pagePosition,
                isChromeVisible: isChromeVisible,
                swipeDismissProgress: swipeDismissProgress,
                isSwipeDismissCommitted: isSwipeDismissCommitted,
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
        .failureAlert(
            feedback?.title ?? "",
            message: feedback?.message,
            details: feedback?.details,
            isPresented: isFeedbackPresented
        ) {
            if feedback?.offersOpenSettings == true {
                Button(L10n.string("favorites.updates.notifications_open_settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(L10n.string("common.cancel"), role: .cancel) {}
            } else {
                Button(L10n.string("common.done"), role: .cancel) {}
            }
        }
        .transientMessage(transientMessage) {
            transientMessage = nil
        }
        .accessibilityIdentifier("reader-image-browser")
    }

    private var currentItem: ImageBrowserItem? {
        items.first { $0.id == selectedItemID } ?? items.first
    }

    @ViewBuilder
    private var imageActionsMenu: some View {
        if currentItem != nil {
            Button {
                Task {
                    await copyImage()
                }
            } label: {
                Label(L10n.string("image.copy"), systemImage: "doc.on.doc")
            }

            if let currentShareable {
                ShareLink(item: currentShareable, preview: SharePreview(currentShareable.title)) {
                    Label(L10n.string("common.share"), systemImage: "square.and.arrow.up")
                }
            }

            Button {
                Task {
                    await saveImage()
                }
            } label: {
                Label(L10n.string("image.save_to_photos"), systemImage: "square.and.arrow.down")
            }

            if !coverActions.isEmpty {
                Divider()
                ForEach(coverActions) { action in
                    Button {
                        Task {
                            await performCoverAction(action)
                        }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }

            if let onEditNote, let currentItem {
                Divider()
                Button {
                    onEditNote(currentItem)
                } label: {
                    Label(
                        L10n.string(currentItem.caption == nil ? "likes.add_note" : "likes.edit_note"),
                        systemImage: "note.text"
                    )
                }
            }

            if let onJumpToOriginal {
                Divider()
                Button(action: onJumpToOriginal) {
                    Label(L10n.string("likes.jump_to_original"), systemImage: "book.closed")
                }
            }
        }
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

    private var backgroundOpacity: Double {
        guard !isSwipeDismissCommitted else { return 0 }
        return 1 - Double(min(max(swipeDismissProgress, 0), 1)) * 0.9
    }

    private var currentShareable: ImageBrowserShareableImage? {
        guard let currentItem, let imagePipeline else { return nil }
        return ImageBrowserShareableImage(
            source: currentItem.source,
            fileExtension: preferredImageExtension(for: currentItem),
            title: currentItem.title,
            imageLoader: imagePipeline.dataLoader
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
            let saver = ImagePhotoSaver()
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
        } catch ImagePhotoSaveError.authorizationDenied {
            guard !Task.isCancelled else { return }
            feedback = .photoPermissionDenied()
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            YamiboLog.reader.error("Image browser action failed for item \(currentItem.id): \(error)")
            feedback = .failure(message: L10n.string("image.action_failed"), details: LoadFailureDetails(error: error))
        }
    }

    private func imageData(for item: ImageBrowserItem) async throws -> Data {
        guard let imagePipeline else { throw YamiboUIImageLoadingError.missingPipeline }
        return try await imagePipeline.dataLoader.data(for: item.source)
    }

    private func preferredImageExtension(for item: ImageBrowserItem) -> String {
        let ext = item.source.url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty, ext.count <= 8 else { return "jpg" }
        return ext
    }

    private func beginSwipeDownDismissCommit() {
        guard !isSwipeDismissCommitted else { return }
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
            onSingleTap: onSingleTap,
            onSwipeDownProgressChange: onSwipeDownProgressChange,
            onSwipeDownCommit: onSwipeDownCommit,
            onSwipeDownDismiss: onSwipeDownDismiss
        )
    }
}

private struct ImageBrowserPageView: View {
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    let item: ImageBrowserItem
    let pageDistance: Int
    let dismissesViaSystemZoomTransition: Bool
    let onSingleTap: () -> Void
    let onSwipeDownProgressChange: (CGFloat) -> Void
    let onSwipeDownCommit: () -> Void
    let onSwipeDownDismiss: () -> Void

    @State private var image: UIImage?
    @State private var animatedData: Data?
    @State private var animationFrame: UIImage?
    @State private var failureDetails: LoadFailureDetails?
    private var didFail: Bool { failureDetails != nil }
    @State private var attempt = 0
    @State private var loadedIdentity: YamiboUIImageRequestIdentity?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages

    var body: some View {
        ImageBrowserZoomableImagePage(
            image: image,
            animationFrame: animationFrame,
            title: item.title,
            isCurrentPage: pageDistance == 0,
            dismissesViaSystemZoomTransition: dismissesViaSystemZoomTransition,
            onSingleTap: onSingleTap,
            onSwipeDownProgressChange: onSwipeDownProgressChange,
            onSwipeDownCommit: onSwipeDownCommit,
            onSwipeDownDismiss: onSwipeDownDismiss
        )
        .overlay {
            ImageBrowserPageStatusOverlay(
                isLoading: image == nil && !didFail,
                didFail: didFail,
                details: failureDetails,
                retry: {
                    failureDetails = nil
                    attempt += 1
                }
            )
        }
        .task(id: LoadIdentity(image: requestIdentity, attempt: attempt, isWithinLoadWindow: isWithinLoadWindow)) {
            await load()
        }
        .task(id: animationIdentity) {
            await playAnimation()
        }
        .onChange(of: pageDistance) { _, _ in
            if !isWithinKeepWindow {
                failureDetails = nil
                image = nil
                animatedData = nil
                animationFrame = nil
            }
        }
    }

    private var isWithinLoadWindow: Bool { pageDistance <= 2 }

    private var isWithinKeepWindow: Bool { pageDistance <= 4 }

    private var animationIdentity: String {
        "\(item.source.cacheKey)#\(animatedData?.count ?? 0)#\(pageDistance == 0)#\(isPlaybackActive)"
    }

    private var isPlaybackActive: Bool {
        scenePhase == .active && playsAnimatedImages
    }

    private struct LoadIdentity: Hashable {
        let image: YamiboUIImageRequestIdentity
        let attempt: Int
        let isWithinLoadWindow: Bool
    }

    private var requestIdentity: YamiboUIImageRequestIdentity {
        .init(cacheKey: item.source.cacheKey, pipelineID: imagePipeline.map(ObjectIdentifier.init),
              source: item.source, revision: imagePipeline?.requestRevision(for: item.source))
    }

    private func load() async {
        if loadedIdentity != requestIdentity {
            image = nil
            animatedData = nil
            animationFrame = nil
            loadedIdentity = requestIdentity
        }
        guard isWithinLoadWindow, image == nil else { return }
        failureDetails = nil
        if let localDataProvider = item.localDataProvider,
           let localData = await localDataProvider(),
           let localImage = UIImage(data: localData) {
            guard !Task.isCancelled else { return }
            image = localImage
            animatedData = YamiboAnimatedImage.isAnimated(localData) ? localData : nil
            return
        }
        do {
            guard let imagePipeline else { throw YamiboUIImageLoadingError.missingPipeline }
            let loaded = try await imagePipeline.displayImage(for: item.source)
            guard !Task.isCancelled else { return }
            image = loaded.image
            animatedData = loaded.animatedData
        } catch {
            guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            YamiboLog.reader.warning("Failed to load image for browser item \(item.id): \(error)")
            failureDetails = LoadFailureDetails(error: error, requestContext: item.source.url.absoluteString)
        }
    }

    private func playAnimation() async {
        animationFrame = nil
        guard let animatedData, let image, pageDistance == 0, isPlaybackActive else { return }
        for await frame in YamiboAnimatedImage.frames(of: animatedData, scale: image.scale) {
            animationFrame = frame
        }
    }
}

private struct ImageBrowserPageStatusOverlay: View {
    let isLoading: Bool
    let didFail: Bool
    let details: LoadFailureDetails?
    let retry: () -> Void

    var body: some View {
        ZStack {
            ProgressView(L10n.string("image.loading"))
                .tint(.white)
                .foregroundStyle(.white.opacity(0.8))
                .opacity(isLoading ? 1 : 0)
                .accessibilityHidden(!isLoading)

            ImageBrowserFailureView(details: details, retry: retry)
                .opacity(didFail ? 1 : 0)
                .accessibilityHidden(!didFail)
        }
        .allowsHitTesting(didFail)
    }
}

private struct ImageBrowserZoomableImagePage: View {
    let image: UIImage?
    let animationFrame: UIImage?
    let title: String
    let isCurrentPage: Bool
    let dismissesViaSystemZoomTransition: Bool
    let onSingleTap: () -> Void
    let onSwipeDownProgressChange: (CGFloat) -> Void
    let onSwipeDownCommit: () -> Void
    let onSwipeDownDismiss: () -> Void

    @State private var zoomProxy = ImageBrowserZoomProxy()
    @State private var zoomFactor: CGFloat = 1
    @State private var isSwipeDismissCommitted = false
    @State private var committedTranslation: CGSize = .zero
    @State private var exitOffset: CGFloat = 0
    @State private var imageOpacity: CGFloat = 1
    @State private var dragTranslation: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ImageBrowserZoomableScrollView(
                    image: image,
                    animationFrame: animationFrame,
                    proxy: zoomProxy,
                    onSingleTap: onSingleTap,
                    onZoomFactorChange: { zoomFactor = $0 }
                )
                .scaleEffect(reduceMotion ? 1 : ImageBrowserSwipeDismissGesture.imageScale(for: swipeProgress))
                .offset(x: swipeOffset.width, y: swipeOffset.height)
                .opacity(imageOpacity)
            }
            .gesture(ImageBrowserDismissPanGesture(
                isEnabled: !dismissesViaSystemZoomTransition && !isSwipeDismissCommitted,
                zoomFactor: zoomFactor,
                onChanged: { dragTranslation = $0 },
                onEnded: { translation, velocity in
                    finishSwipeDismiss(translation: translation, velocity: velocity, containerSize: geometry.size)
                },
                onCancelled: cancelSwipeDismiss
            ))
        }
        .onChange(of: swipeProgress) { _, newValue in
            onSwipeDownProgressChange(newValue)
        }
        .onChange(of: isCurrentPage) { _, isCurrentPage in
            guard !isCurrentPage else { return }
            zoomProxy.resetZoom(animated: false)
            dragTranslation = .zero
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
            : CGSize(width: dragTranslation.x, height: dragTranslation.y)
    }

    private var swipeProgress: CGFloat {
        isSwipeDismissCommitted ? 1 : ImageBrowserSwipeDismissGesture.progress(for: dragTranslation.y)
    }

    private func cancelSwipeDismiss() {
        guard !isSwipeDismissCommitted, dragTranslation != .zero else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            dragTranslation = .zero
        }
    }

    private func finishSwipeDismiss(translation: CGPoint, velocity: CGPoint, containerSize: CGSize) {
        guard !dismissesViaSystemZoomTransition, !isSwipeDismissCommitted else { return }
        guard !isZoomedIn, ImageBrowserSwipeDismissGesture.shouldDismiss(
            translation: translation, velocity: velocity, zoomScale: zoomFactor, minimumZoomScale: 1
        ) else {
            cancelSwipeDismiss()
            return
        }
        commitSwipeDismiss(translation: translation, velocity: velocity, containerSize: containerSize)
    }

    private func commitSwipeDismiss(translation: CGPoint, velocity: CGPoint, containerSize: CGSize) {
        isSwipeDismissCommitted = true
        committedTranslation = CGSize(width: translation.x, height: max(translation.y, 0))
        onSwipeDownCommit()

        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2), completionCriteria: .logicallyComplete) {
                imageOpacity = 0
            } completion: {
                onSwipeDownDismiss()
            }
            return
        }

        let imageHeight = image.map {
            ImageContentGeometry.aspectFitFrame(imageSize: $0.size, containerSize: containerSize).height
        } ?? 0
        let exitDistance = max(
            containerSize.height - committedTranslation.height + imageHeight * 0.35,
            containerSize.height * 0.45
        )
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
    var details: LoadFailureDetails?
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Label(L10n.string("image.load_failed"), systemImage: "photo")
                .foregroundStyle(.white.opacity(0.8))

            if let retry {
                Button(action: retry) {
                    Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
                }
                .appProminentButtonStyle()
                .controlSize(.regular)
                LoadFailureDetailsButton(details: details, message: L10n.string("image.load_failed"))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
    }
}

private struct ImageBrowserToolbar: View {
    let title: String
    let caption: String?
    let pagePosition: (index: Int, count: Int)?
    let isChromeVisible: Bool
    let swipeDismissProgress: CGFloat
    let isSwipeDismissCommitted: Bool
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ImageBrowserTopBar(
                    title: title,
                    pagePosition: pagePosition,
                    onDismiss: onDismiss
                )

                Spacer(minLength: 0)

                if let caption {
                    ImageBrowserCaptionPanel(
                        caption: caption,
                        maximumHeight: geometry.size.height * 0.35
                    )
                }
            }
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

private struct ImageBrowserTopBar: View {
    let title: String
    let pagePosition: (index: Int, count: Int)?
    let onDismiss: () -> Void

    var body: some View {
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
    }
}

struct ImageBrowserCaptionPanel: View {
    let caption: String
    let maximumHeight: CGFloat

    var body: some View {
        ImageBrowserCaptionLayout(maximumHeight: maximumHeight) {
            ImageBrowserCaptionText(caption: caption)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)

            ScrollView {
                ImageBrowserCaptionText(caption: caption)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.62))
    }
}

private struct ImageBrowserCaptionLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let measurement = subviews.first else { return .zero }
        let measuredSize = measurement.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        let heightLimit = min(maximumHeight, proposal.height ?? maximumHeight)
        return CGSize(
            width: proposal.width ?? measuredSize.width,
            height: min(measuredSize.height, heightLimit)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count > 1 else { return }
        subviews[subviews.index(after: subviews.startIndex)].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

private struct ImageBrowserCaptionText: View {
    let caption: String

    var body: some View {
        Text(caption)
            .font(.callout)
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
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
    var details: LoadFailureDetails? = nil

    static func failure(message: String, details: LoadFailureDetails? = nil) -> ImageBrowserFeedback {
        ImageBrowserFeedback(title: L10n.string("common.operation_failed"), message: message, details: details)
    }

    static func photoPermissionDenied() -> ImageBrowserFeedback {
        ImageBrowserFeedback(
            title: L10n.string("image.save_photo_permission_denied_title"),
            message: L10n.string("image.save_photo_permission_denied"),
            offersOpenSettings: true,
            details: LoadFailureDetails(error: ImagePhotoSaveError.authorizationDenied)
        )
    }
}

private struct ImageBrowserShareableImage: Transferable {
    let source: YamiboImageSource
    let fileExtension: String
    let title: String
    let imageLoader: any YamiboImageDataLoading

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { shareable in
            let data = try await shareable.imageLoader.data(for: shareable.source)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(shareable.fileExtension)
            try data.write(to: fileURL, options: .atomic)
            return SentTransferredFile(fileURL)
        }
    }
}
#endif
