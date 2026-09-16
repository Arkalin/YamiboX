import SwiftUI
import YamiboXCore

struct ForumComposerDraftList: View {
    let model: ForumPageSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if case let .failed(message) = model.composerDraft.status {
                    Section { Text(message).font(.footnote).foregroundStyle(.red) }
                }
                if model.composerDraft.available.isEmpty {
                    ContentUnavailableView(L10n.string("forum.composer.no_drafts"), systemImage: "doc")
                }
                ForEach(model.composerDraft.available) { draft in
                    Button { Task { await model.restoreDraft(draft) } } label: {
                        ForumComposerDraftRow(draft: draft)
                    }
                    .disabled(model.isLoading)
                    .swipeActions { Button(L10n.string("common.delete"), role: .destructive) { Task { await model.deleteDraft(draft) } } }
                }
            }
            .navigationTitle(L10n.string("forum.composer.drafts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.string("common.done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { _ = await model.flushLocalDraft(force: true); await model.composerDraft.reloadList() } } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel(L10n.string("forum.composer.save_current_draft"))
                        .disabled(model.isLoading || model.composerDraft.active != true)
                }
            }
            .overlay { if model.isLoading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
            .alert(L10n.string("forum.composer.server_changed"), isPresented: Binding(get: { model.draftConflict != nil }, set: { if !$0 { model.draftConflict = nil } })) {
                Button(L10n.string("forum.composer.use_local")) { Task { await model.resolveDraftConflict(useLocal: true) } }
                Button(L10n.string("forum.composer.use_server")) { Task { await model.resolveDraftConflict(useLocal: false) } }
                Button(L10n.string("common.cancel"), role: .cancel) { model.draftConflict = nil }
            } message: { Text(L10n.string("forum.composer.server_changed_message")) }
        }
    }
}

private struct ForumComposerDraftRow: View {
    let draft: ForumComposerDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.title.isEmpty ? L10n.string("forum.composer.untitled_draft") : draft.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
            Text(String(ForumComposerDocument(source: draft.source).plainText().prefix(2000))).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Text(L10n.string("forum.composer.target." + draft.target.kind.rawValue))
                if let target = draft.target.threadID ?? draft.target.forumID { Text("#" + target) }
                Spacer(minLength: 0)
                Text(draft.updatedAt, format: .dateTime.month().day().hour().minute())
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ForumComposerAssetSection: View {
    let model: ForumPageSession
    let form: ForumForm
    var body: some View {
        if !model.composerAssets.isEmpty {
            Section(L10n.string("forum.composer.local_attachments")) {
                ForEach(model.composerAssets) { asset in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: asset.isImage ? "photo" : "paperclip").frame(width: 24, height: 24).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.name).font(.subheadline).lineLimit(2)
                            if let failure = model.assetFailures[asset.id] { Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3) }
                            else if asset.uploadID != nil {
                                Text(L10n.string(asset.inserted ? "forum.composer.asset_inserted" : "forum.composer.asset_not_inserted")).font(.caption).foregroundStyle(.secondary)
                            } else if asset.fieldName == nil { Text(L10n.string("forum.composer.asset_pending")).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if model.uploadingAssetID == asset.id { ProgressView().frame(width: 44, height: 44) }
                        else {
                            if asset.uploadID != nil {
                                ForumComposerIconButton(symbol: "text.insert", title: L10n.string("forum.composer.insert_attachment")) { model.insertAsset(asset.id, form: form) }
                            } else if asset.fieldName == nil {
                                ForumComposerIconButton(symbol: "arrow.clockwise", title: L10n.string("forum.composer.retry_upload")) { Task { await model.retryAsset(asset.id, form: form) } }
                                    .disabled(model.isOfflineDraft || model.isUploading)
                            }
                            ForumComposerIconButton(symbol: "xmark.circle", title: L10n.string("common.remove")) { Task { await model.removeAsset(asset.id, form: form) } }
                        }
                    }.disabled(model.isSubmitting)
                }
            }
        }
    }
}
