import SwiftUI
import YamiboXCore

@MainActor
struct ReaderDeviceInteraction: Identifiable {
    let id: UUID
    let sessionID: UUID
    let contentID: UUID
    let account: UUID
    let body: AnyView

    func validate(session: ReaderSession, appModel: YamiboAppModel) -> Bool {
        sessionID == session.id && contentID == session.contentID && account == appModel.accountGeneration
    }
}

@MainActor
struct ReaderDeviceInteractionContext {
    let display: ReaderExternalDisplayCoordinator
    let session: ReaderSession
    let appModel: YamiboAppModel

    func showMenu(from viewport: ReaderViewportLifetime) {
        display.showDeviceMenu(for: session, from: viewport)
    }

    func present<Content: View>(@ViewBuilder content: (UUID) -> Content) {
        let id = UUID()
        let interaction = ReaderDeviceInteraction(id: id, sessionID: session.id, contentID: session.contentID,
            account: appModel.accountGeneration,
            body: AnyView(content(id)))
        display.beginDeviceInteraction(interaction, session: session)
    }

    func editNote(_ item: LikeItem, save: @escaping (String?) async -> Bool) {
        present { id in
            ReaderDeviceNoteEditor(item: item, save: { note in
                guard isCurrent(id) else { return false }
                return await save(note)
            }, onClose: { finish(id) })
        }
    }

    func showDetails(_ details: LoadFailureDetails) {
        present { id in LoadFailureDetailsSheet(details: details, onClose: { finish(id) }) }
    }

    func isCurrent(_ id: UUID) -> Bool {
        session.deviceInteraction?.id == id && session.deviceInteraction?.account == appModel.accountGeneration &&
            session.deviceInteraction?.contentID == session.contentID && !session.isClosed
    }

    func finish(_ id: UUID) {
        guard isCurrent(id) else { return }
        display.finishDeviceInteraction(id: id, session: session)
    }
}

struct ReaderDeviceNoteEditor: View {
    let item: LikeItem
    let save: (String?) async -> Bool
    let onClose: () -> Void
    @State private var text: String
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    init(item: LikeItem, save: @escaping (String?) async -> Bool, onClose: @escaping () -> Void) {
        self.item = item
        self.save = save
        self.onClose = onClose
        _text = State(initialValue: item.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let excerpt = item.excerptText {
                    Text(excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                TextEditor(text: $text).focused($focused)
                if failed { Text(L10n.string("common.operation_failed")).foregroundStyle(.red) }
            }
            .padding(12)
            .disabled(saving)
            .navigationTitle(L10n.string("likes.note_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onClose).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        guard !saving else { return }
                        saving = true
                    }
                    .disabled(saving)
                }
            }
            .task { focused = true }
            .task(id: saving) {
                guard saving else { return }
                let succeeded = await save(text)
                guard !Task.isCancelled else { return }
                if succeeded { onClose() } else { saving = false; failed = true }
            }
        }
        .interactiveDismissDisabled()
    }
}

extension EnvironmentValues {
    @Entry var readerDeviceInteraction: ReaderDeviceInteractionContext? = nil
}
