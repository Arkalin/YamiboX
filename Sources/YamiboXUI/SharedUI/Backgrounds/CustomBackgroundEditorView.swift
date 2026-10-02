import SwiftUI
import YamiboXCore
import UIKit

struct CustomBackgroundEditorDraft: Identifiable {
    let id = UUID()
    var imageData: Data?
    var imageSize: CGSize
    var settings: CustomBackgroundSettings
    var showsOverlay = true

    static func custom(
        imageData: Data,
        settings: CustomBackgroundSettings = CustomBackgroundSettings(isEnabled: true)
    ) -> CustomBackgroundEditorDraft? {
        guard let imageSize = customBackgroundImageSize(from: imageData) else { return nil }
        return CustomBackgroundEditorDraft(
            imageData: imageData,
            imageSize: imageSize,
            settings: CustomBackgroundSettings(
                isEnabled: true,
                imageID: settings.imageID,
                scale: settings.scale,
                offsetX: settings.offsetX,
                offsetY: settings.offsetY,
                blurRadius: settings.blurRadius
            )
        )
    }

    mutating func replaceImage(with data: Data) -> Bool {
        guard let newSize = customBackgroundImageSize(from: data) else { return false }
        let currentBlurRadius = settings.blurRadius
        imageData = data
        imageSize = newSize
        settings = CustomBackgroundSettings(
            isEnabled: true,
            scale: 1,
            offsetX: 0,
            offsetY: 0,
            blurRadius: currentBlurRadius
        )
        return true
    }

    mutating func restoreDefault() {
        imageData = nil
        imageSize = .zero
        settings = CustomBackgroundSettings()
        showsOverlay = true
    }
}

struct CustomBackgroundEditorView<Preview: View>: View {
    @Binding var draft: CustomBackgroundEditorDraft

    let onCancel: () -> Void
    let onChangeImage: () -> Void
    let onApply: (CustomBackgroundEditorDraft) async -> Bool
    var showsFramedPreview = false
    var supportsBlur = true
    var isLoadingImage = false
    var supportsOverlayVisibility = false
    @ViewBuilder var preview: (Data?, CustomBackgroundSettings, CGSize) -> Preview

    @Environment(\.colorScheme) private var colorScheme
    /// The reset transactions match the `withAnimation` in the gesture `onEnded`s,
    /// so a rubber-banded overshoot springs back smoothly instead of snapping
    /// when the gesture state clears.
    @GestureState(resetTransaction: Transaction(animation: .gestureSettle))
    private var dragTranslation: CGSize = .zero
    @GestureState(resetTransaction: Transaction(animation: .gestureSettle))
    private var magnification = 1.0
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Group {
                if showsFramedPreview {
                    framedEditor
                } else {
                    GeometryReader { geometry in
                        ZStack {
                            editorBackground
                            canvas(size: geometry.size, referenceSize: geometry.size)
                            bottomControls
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .ignoresSafeArea()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                        .disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: applyCurrentDraft) {
                        ApplyButtonLabel(isApplying: isApplying)
                    }
                    .disabled(isApplying || isLoadingImage)
                }
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    private var framedEditor: some View {
        GeometryReader { geometry in
            let referenceSize = CGSize(width: geometry.size.width,
                                       height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            VStack(spacing: 20) {
                GeometryReader { available in
                    let size = fittedPreviewSize(in: available.size, aspectRatio: referenceSize.width / max(1, referenceSize.height))
                    canvas(size: size, referenceSize: referenceSize)
                        .frame(width: size.width, height: size.height)
                        .clipShape(.rect(cornerRadius: 22))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                        }
                        .position(x: available.size.width / 2, y: available.size.height / 2)
                }
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(YamiboColors.SystemSurface.groupedBackground.ignoresSafeArea())
        }
    }

    private func fittedPreviewSize(in available: CGSize, aspectRatio: CGFloat) -> CGSize {
        let width = min(available.width, available.height * aspectRatio)
        return CGSize(width: max(1, width), height: max(1, width / aspectRatio))
    }

    private func canvas(size: CGSize, referenceSize: CGSize) -> some View {
        let blurScale = size.width / max(1, referenceSize.width)
        var settings = liveSettings(containerSize: size)
        settings.blurRadius *= blurScale
        return ZStack {
            colorScheme == .dark ? Color.black : Color.white
            if let imageData = draft.imageData {
                editableImage(data: imageData, containerSize: size, blurScale: blurScale)
            }
            if draft.showsOverlay {
                preview(draft.imageData, settings, referenceSize)
                    .allowsHitTesting(false)
            }
        }
    }

    private func liveSettings(containerSize: CGSize) -> CustomBackgroundSettings {
        var settings = draft.settings
        settings.scale = CustomBackgroundSettings.clampScale(settings.scale * magnification)
        let offsets = CustomBackgroundLayout.normalizedOffsets(
            imageSize: draft.imageSize, containerSize: containerSize, scale: settings.scale,
            proposedOffset: currentRenderedFrame(containerSize: containerSize).offset
        )
        settings.offsetX = offsets.offsetX
        settings.offsetY = offsets.offsetY
        return settings
    }

    private var editorBackground: some View {
        ZStack {
            YamiboColors.SystemSurface.background

            if draft.imageData == nil {
                Color.secondary.opacity(colorScheme == .dark ? 0.16 : 0.08)
            }
        }
        .ignoresSafeArea()
    }

    private func editableImage(data: Data, containerSize: CGSize, blurScale: CGFloat) -> some View {
        let frame = currentRenderedFrame(containerSize: containerSize)

        return CustomBackgroundImage(data: data)
            .frame(width: frame.size.width, height: frame.size.height)
            .offset(frame.offset)
            .blur(radius: draft.settings.blurRadius * blurScale)
            .clipped()
            .frame(width: containerSize.width, height: containerSize.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(containerSize: containerSize))
            .simultaneousGesture(magnificationGesture(containerSize: containerSize))
            .allowsHitTesting(!isApplying && !isLoadingImage)
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            Spacer()

            controls
            .padding(.horizontal, 24)
            .padding(.bottom, 72)
        }
    }

    private var controls: some View {
        CustomBackgroundEditorBottomControls(draft: $draft, isApplying: isApplying || isLoadingImage,
                                             supportsBlur: supportsBlur, supportsOverlayVisibility: supportsOverlayVisibility,
                                             onChangeImage: onChangeImage)
    }

    private func applyCurrentDraft() {
        Task {
            isApplying = true
            let didApply = await onApply(draft)
            if !didApply {
                isApplying = false
            }
        }
    }

    private func dragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard draft.imageSize != .zero else { return }
                // Land where the flick was heading (projected momentum),
                // clamped back inside the croppable bounds.
                let projection = GesturePhysics.project(
                    value.velocity,
                    decelerationRate: GesturePhysics.DecelerationRate.fast
                )
                let proposedOffset = clampedOffset(
                    baseOffset(containerSize: containerSize) + value.translation + projection,
                    containerSize: containerSize,
                    scale: draft.settings.scale
                )
                let offsets = CustomBackgroundLayout.normalizedOffsets(
                    imageSize: draft.imageSize,
                    containerSize: containerSize,
                    scale: draft.settings.scale,
                    proposedOffset: proposedOffset
                )
                withAnimation(.gestureSettle) {
                    draft.settings.offsetX = offsets.offsetX
                    draft.settings.offsetY = offsets.offsetY
                }
            }
    }

    private func magnificationGesture(containerSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let offsets = CustomBackgroundLayout.normalizedOffsets(
                    imageSize: draft.imageSize,
                    containerSize: containerSize,
                    scale: CustomBackgroundSettings.clampScale(draft.settings.scale * value),
                    proposedOffset: baseOffset(containerSize: containerSize)
                )
                withAnimation(.gestureSettle) {
                    draft.settings.scale = CustomBackgroundSettings.clampScale(draft.settings.scale * value)
                    draft.settings.offsetX = offsets.offsetX
                    draft.settings.offsetY = offsets.offsetY
                }
            }
    }

    private func currentRenderedFrame(containerSize: CGSize) -> CustomBackgroundRenderedFrame {
        let currentSettings = CustomBackgroundSettings(
            isEnabled: draft.settings.isEnabled,
            imageID: draft.settings.imageID,
            scale: draft.settings.scale * magnification,
            offsetX: draft.settings.offsetX,
            offsetY: draft.settings.offsetY,
            blurRadius: draft.settings.blurRadius
        )
        let baseFrame = CustomBackgroundLayout.renderedFrame(
            imageSize: draft.imageSize,
            containerSize: containerSize,
            settings: currentSettings
        )
        let offset = rubberBandedOffset(
            baseFrame.offset + dragTranslation,
            containerSize: containerSize,
            scale: currentSettings.scale
        )
        return CustomBackgroundRenderedFrame(size: baseFrame.size, offset: offset)
    }

    private func baseOffset(containerSize: CGSize) -> CGSize {
        CustomBackgroundLayout.renderedFrame(
            imageSize: draft.imageSize,
            containerSize: containerSize,
            settings: draft.settings
        ).offset
    }

    private func clampedOffset(
        _ offset: CGSize,
        containerSize: CGSize,
        scale: Double
    ) -> CGSize {
        let frame = CustomBackgroundLayout.renderedFrame(
            imageSize: draft.imageSize,
            containerSize: containerSize,
            settings: CustomBackgroundSettings(scale: scale)
        )
        let overflowX = max(0, (frame.size.width - containerSize.width) / 2)
        let overflowY = max(0, (frame.size.height - containerSize.height) / 2)
        return CGSize(
            width: min(overflowX, max(-overflowX, offset.width)),
            height: min(overflowY, max(-overflowY, offset.height))
        )
    }

    /// Live-drag variant of `clampedOffset`: edges give with rubber-band
    /// resistance while the finger is down; `onEnded` clamps and the reset
    /// transaction springs the overshoot back.
    private func rubberBandedOffset(
        _ offset: CGSize,
        containerSize: CGSize,
        scale: Double
    ) -> CGSize {
        let frame = CustomBackgroundLayout.renderedFrame(
            imageSize: draft.imageSize,
            containerSize: containerSize,
            settings: CustomBackgroundSettings(scale: scale)
        )
        let overflowX = max(0, (frame.size.width - containerSize.width) / 2)
        let overflowY = max(0, (frame.size.height - containerSize.height) / 2)
        return CGSize(
            width: GesturePhysics.rubberBanded(
                offset.width,
                lower: -overflowX,
                upper: overflowX,
                dimension: containerSize.width
            ),
            height: GesturePhysics.rubberBanded(
                offset.height,
                lower: -overflowY,
                upper: overflowY,
                dimension: containerSize.height
            )
        )
    }
}

private struct CustomBackgroundImage: View {
    let data: Data

    var body: some View {
        if let image = CustomBackgroundImageDecodeCache.shared.image(for: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

/// Memoizes `UIImage(data:)` decoding so repeated `body` evaluations with the
/// same background image `Data` reuse the same `UIImage` instance instead of
/// redecoding and losing identity (which would otherwise defeat SwiftUI's
/// diffing and force `.blur(radius:)` to re-render every time an unrelated
/// state change reevaluates the favorites root, which this view wraps).
final class CustomBackgroundImageDecodeCache: @unchecked Sendable {
    static let shared = CustomBackgroundImageDecodeCache()

    private let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 4
        return cache
    }()

    func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

private struct CustomBackgroundEditorBottomControls: View {
    @Binding var draft: CustomBackgroundEditorDraft

    let isApplying: Bool
    let supportsBlur: Bool
    let supportsOverlayVisibility: Bool
    let onChangeImage: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 14) {
            if supportsOverlayVisibility {
                AppThemeSwitch(L10n.string("custom_background.show_icon"), isOn: $draft.showsOverlay)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .sharedGlassPanel(cornerRadius: 18)
                    .disabled(isApplying)
            }
            if supportsBlur {
                CustomBackgroundBlurControl(blurRadius: blurRadiusBinding)
                    .disabled(isApplying || draft.imageData == nil)
            }

            SharedGlassContainer(spacing: 12) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    CustomBackgroundRestoreDefaultButton(
                        isApplying: isApplying || (draft.imageData == nil && (!supportsOverlayVisibility || draft.showsOverlay)),
                        action: restoreDefault
                    )
                    CustomBackgroundChangeImageButton(isApplying: isApplying, action: onChangeImage)
                }
            }
        }
        .frame(maxWidth: 440)
    }

    private var blurRadiusBinding: Binding<Double> {
        Binding(
            get: { draft.settings.blurRadius },
            set: { draft.settings.blurRadius = CustomBackgroundSettings.clampBlurRadius($0.rounded()) }
        )
    }

    private func restoreDefault() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            draft.restoreDefault()
        }
    }
}

private struct CustomBackgroundBlurControl: View {
    @Binding var blurRadius: Double

    var body: some View {
        blurContent
            .padding(16)
            .frame(maxWidth: 360)
            .sharedGlassPanel(cornerRadius: 18)
    }

    private var blurContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("custom_background.blur"))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(Int(blurRadius.rounded()))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { blurRadius },
                    set: { blurRadius = CustomBackgroundSettings.clampBlurRadius($0.rounded()) }
                ),
                in: CustomBackgroundSettings.minimumBlurRadius...CustomBackgroundSettings.maximumBlurRadius,
                step: 1
            )
        }
    }
}

private struct CustomBackgroundChangeImageButton: View {
    let isApplying: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Button(action: action, label: label)
            .font(.subheadline.weight(.semibold))
            .sharedGlassButtonStyle(prominent: true, tint: appTheme.forumTheme.prominentSurface)
            .foregroundStyle(.white)
            .disabled(isApplying)
    }

    private func label() -> some View {
        Label(L10n.string("custom_background.change_image"), systemImage: "photo.on.rectangle.angled")
            .frame(maxWidth: .infinity, minHeight: 32)
    }
}

private struct CustomBackgroundRestoreDefaultButton: View {
    let isApplying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.string("custom_background.restore_default"), systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .font(.subheadline.weight(.semibold))
        .sharedGlassButtonStyle(tint: .primary)
        .disabled(isApplying)
    }
}

private struct ApplyButtonLabel: View {
    let isApplying: Bool

    var body: some View {
        if isApplying {
            ProgressView()
                .frame(minWidth: 38)
        } else {
            Text(L10n.string("common.apply"))
                .fontWeight(.semibold)
        }
    }
}

private func customBackgroundImageSize(from data: Data) -> CGSize? {
    CustomBackgroundImageDecodeCache.shared.image(for: data)?.size
}

private func + (lhs: CGSize, rhs: CGSize) -> CGSize {
    CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
}
