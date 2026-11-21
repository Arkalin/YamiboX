import SwiftUI
import YamiboXCore

/// The external canvas has no device popover anchor. Keep its image actions
/// and their child presentations together in one native device sheet.
struct MangaReaderDeviceImageActions: View {
    let image: ImageBrowserItem
    let likedItem: LikeItem?
    let setCover: (() -> Void)?
    let restoreCover: (() -> Void)?
    let addLike: () -> Void
    let removeLike: (LikeItem) -> Void
    let createNoteItem: () async -> LikeItem?
    let saveNote: (LikeItem, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showsImage = false
    @State private var createsNoteItem = false
    @State private var noteItem: LikeItem?

    var body: some View {
        NavigationStack {
            List {
                Button(L10n.string("reader.comment_view_image")) { showsImage = true }
                if let setCover {
                    Button(L10n.string("cover.set_as_cover")) { dismiss(); setCover() }
                }
                if let restoreCover {
                    Button(L10n.string("cover.restore_auto_cover")) { dismiss(); restoreCover() }
                }
                Button(L10n.string(likedItem?.hasNote == true ? "likes.edit_note" : "likes.add_note")) {
                    if let likedItem { noteItem = likedItem } else { createsNoteItem = true }
                }
                if let likedItem {
                    Button(L10n.string("likes.remove_like"), role: .destructive) { dismiss(); removeLike(likedItem) }
                } else {
                    Button(L10n.string("likes.add_to_likes")) { dismiss(); addLike() }
                }
            }
            .disabled(createsNoteItem)
            .navigationTitle(L10n.string("image.actions.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) { dismiss() }
                }
            }
        }
        .task(id: createsNoteItem) {
            guard createsNoteItem else { return }
            let item = await createNoteItem()
            guard !Task.isCancelled else { return }
            noteItem = item
            createsNoteItem = false
            if item == nil { dismiss() }
        }
        .imageBrowserCover(isPresented: $showsImage) {
            ImageBrowserView(items: [image], initialItemID: image.id, mode: .single) { showsImage = false }
        }
        .sheet(item: $noteItem) { item in
            ReaderDeviceNoteEditor(item: item, save: { await saveNote(item, $0) }, onClose: { noteItem = nil })
        }
    }
}
