import SwiftUI
import YamiboXCore

/// On-device counterpart of the novel reader's edit menu. Only the controls
/// live here; the current external viewport still resolves and acts on text.
struct ReaderDeviceTextMenu: View {
    let menu: NovelTextMenu
    @State private var chooseStyle: ((LikeStyle) -> Void)?

    static func show(for item: LikeItem?, selection: NovelTextSelectionController,
                     highlights: NovelLikeHighlightController, input: ReaderExternalInput,
                     device: ReaderDeviceInteractionContext, viewport: ReaderViewportLifetime, attachment: UUID) {
        guard input.isEnabled, viewport.acceptsInput(attachment) else { return }
        if item != nil { selection.clearSelection() }
        let id = UUID()
        let currentDevice = { [weak display = device.display, weak session = device.session, weak app = device.appModel]
            () -> ReaderDeviceInteractionContext? in
            guard let display, let session, let app else { return nil }
            return ReaderDeviceInteractionContext(display: display, session: session, appModel: app)
        }
        let admits = { [weak input, weak viewport] in
            input?.isEnabled == true && input?.textMenu?.id == id && viewport?.acceptsInput(attachment) == true
        }
        input.updateTextMenu(selection.textMenu(
            id: id, item: item, highlights: highlights, admits: admits,
            share: { currentDevice()?.shareText($0) }, lookUp: { currentDevice()?.lookUpText($0) },
            didCapture: { [weak selection, weak highlights, weak input, weak viewport] item in
                guard admits(), let selection, let highlights, let input, let viewport,
                      let device = currentDevice() else { return }
                show(for: item, selection: selection, highlights: highlights, input: input,
                     device: device, viewport: viewport, attachment: attachment)
            },
            dismissAnnotation: { [weak input] in input?.updateTextMenu(nil) }
        ))
    }

    var body: some View {
        Group {
            if let chooseStyle {
                VStack(spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) { swatches(NovelLikeStyleMenu.styles, choose: chooseStyle) }
                        VStack(spacing: 4) {
                            HStack(spacing: 4) { swatches(NovelLikeStyleMenu.styles.prefix(3), choose: chooseStyle) }
                            HStack(spacing: 4) { swatches(NovelLikeStyleMenu.styles.dropFirst(3), choose: chooseStyle) }
                        }
                    }
                    textButton(L10n.string("common.back")) { self.chooseStyle = nil }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { actions }
                    VStack(spacing: 0) { actions }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
    }

    private var actions: some View {
        ForEach(menu.actions) { action in
            switch action.command {
            case let .perform(perform):
                textButton(action.title, role: action.destructive ? .destructive : nil, perform: perform)
            case let .styles(choose):
                textButton(action.title) { chooseStyle = choose }
            case let .disabled(reason):
                VStack(spacing: 0) {
                    textButton(action.title) {}.disabled(true)
                    Text(reason).font(.caption).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func textButton(_ title: String, role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Text(title)
                .multilineTextAlignment(.center)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private func swatches<S: Sequence>(_ styles: S, choose: @escaping (LikeStyle) -> Void) -> some View where S.Element == LikeStyle {
        ForEach(Array(styles), id: \.self) { style in
            Button {
                chooseStyle = nil
                choose(style)
            } label: {
                Image(uiImage: NovelLikeStyleMenu.swatchImage(for: style))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.string("likes.style.\(style.rawValue)"))
        }
    }
}
