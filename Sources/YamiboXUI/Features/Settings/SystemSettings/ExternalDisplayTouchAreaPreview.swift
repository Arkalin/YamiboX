import SwiftUI
import YamiboXCore

struct ExternalDisplayTouchAreaPreview: View {
    let viewModel: SettingsPeripheralsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Double
    @State private var isSaving = false
    @GestureState private var dragOffset: CGFloat? = nil

    private static let previewSpace = "external-display-touch-area-preview"
    private var title: String { L10n.string("settings.external_display.touch_area") }

    init(viewModel: SettingsPeripheralsViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.externalDisplay.trackpadHeightRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            let ratio = adjustedRatio(by: dragOffset ?? 0, in: proxy.size.height)
            let displayRatio = (ratio * 100).rounded() / 100
            let layout = ReaderDeviceTrackpadLayout(height: proxy.size.height, trackpadRatio: ratio)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    region(L10n.string("reader.external.trackpad"), ratio: displayRatio)
                        .padding(.top, 52)
                        .padding(.bottom, 22)
                        .frame(height: layout.trackpadHeight)
                    region(L10n.string("settings.external_display.touch_area.controls"), ratio: 1 - displayRatio)
                        .frame(height: layout.controlsHeight)
                        .background(Color(white: 0.14))
                        .overlay(alignment: .top) {
                            Color.white.opacity(0.18)
                                .frame(height: 1)
                        }
                }
                .allowsHitTesting(false)

                resizeHandle(height: proxy.size.height, ratio: displayRatio)
                    .position(x: proxy.size.width / 2, y: layout.trackpadHeight)

                header
            }
            .coordinateSpace(name: Self.previewSpace)
        }
        .background(Color(white: 0.08).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled()
        .sensoryFeedback(trigger: dragOffset != nil) { _, isDragging in
            isDragging ? .impact(weight: .light) : .impact(weight: .medium)
        }
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: .presentation(
                isPresented: { viewModel.errorMessage != nil },
                clearOnDismiss: { viewModel.errorMessage = nil }
            )
        ) {
            Button(L10n.string("common.ok")) { viewModel.errorMessage = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) {
                dismiss()
            } label: {
                Label(L10n.string("common.cancel"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            Button {
                save()
            } label: {
                Label(L10n.string("common.save"), systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .disabled(isSaving)
    }

    private func region(_ label: String, ratio: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Text(percent(ratio))
                .monospacedDigit()
        }
        .font(.body.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(Color(white: 0.85))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func resizeHandle(height: CGFloat, ratio: Double) -> some View {
        Image(systemName: "arrow.up.and.down")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 28)
            .background(Color(white: 0.28), in: .capsule)
            .frame(width: 76, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.previewSpace))
                    .updating($dragOffset) { value, offset, _ in offset = value.translation.height }
                    .onEnded { value in draft = adjustedRatio(by: value.translation.height, in: height) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("settings.external_display.touch_area.handle"))
            .accessibilityValue(percent(ratio))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: draft = ExternalDisplaySettings.clampTrackpadHeightRatio(draft + 0.01)
                case .decrement: draft = ExternalDisplaySettings.clampTrackpadHeightRatio(draft - 0.01)
                @unknown default: break
                }
            }
            .disabled(isSaving)
    }

    private func adjustedRatio(by offset: CGFloat, in height: CGFloat) -> Double {
        guard height > 0 else { return draft }
        return ExternalDisplaySettings.clampTrackpadHeightRatio(draft + Double(offset / height))
    }

    private func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let ratio = draft
        Task {
            if await viewModel.updateTrackpadHeightRatio(ratio) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}
