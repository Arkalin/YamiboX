import SwiftUI
import YamiboXCore

enum ForumComposerLabels {
    static func title(_ tag: ForumComposerTag) -> String { L10n.string("forum.composer.tag." + tag.rawValue) }
    static func symbol(_ tag: ForumComposerTag) -> String {
        switch tag {
        case .b: "bold"
        case .i: "italic"
        case .u: "underline"
        case .s: "strikethrough"
        case .font: "textformat"
        case .size: "textformat.size"
        case .color: "a.square.fill"
        case .backcolor: "highlighter"
        case .sup: "textformat.superscript"
        case .sub: "textformat.subscript"
        case .align, .p: "text.alignleft"
        case .indent: "increase.indent"
        case .float: "rectangle.leadinghalf.inset.filled"
        case .lineh: "arrow.up.and.down.text.horizontal"
        case .list, .item: "list.bullet"
        case .hr: "minus"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .table, .tr, .td: "tablecells"
        case .ruby: "character.phonetic"
        case .collapse: "chevron.down.square"
        case .hide: "eye.slash"
        case .free: "lock.open"
        case .url: "link"
        case .email: "envelope"
        case .img, .attachimg: "photo"
        case .attach: "paperclip"
        case .audio: "waveform"
        case .media: "film"
        case .flash, .swf: "doc.badge.gearshape"
        case .password: "key"
        case .postbg: "photo.on.rectangle"
        case .page: "rectangle.split.1x2"
        case .index, .indexEntry: "list.bullet.rectangle"
        case .begin: "rectangle.on.rectangle"
        case .fly: "text.append"
        case .qq: "person.crop.square"
        case .groupid: "person.2.badge.key"
        }
    }
    static func defaultParameter(_ tag: ForumComposerTag) -> String {
        switch tag {
        case .size: "3"
        case .font: "Arial"
        case .color: "#FF0000"
        case .backcolor: "#FFFF00"
        case .align, .float: "left"
        case .p: "30, 2, left"
        case .lineh: "1.7"
        case .collapse: "0,"
        case .media: "mp4,640,360"
        case .flash: "640,360"
        case .indexEntry: "1"
        default: ""
        }
    }
}

struct ForumComposerIconButton: View {
    let symbol: String
    let title: String
    var selected = false
    var mixed = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottom) { if mixed { Rectangle().frame(width: 12, height: 2).padding(.bottom, 4) } }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? L10n.string("forum.composer.selected") : mixed ? L10n.string("forum.composer.mixed") : "")
        .help(title)
    }
}

struct ForumBBCodeEditor: View {
    @Binding var text: String
    let controller: ForumEditorController
    var composerContext = ForumComposerContext()
    var parsesBBCode = true
    var parsesEmoticons = true
    var compact = false
    var onDrafts: (() -> Void)?
    var draftStatus: String?
    @State private var showsEmoticons = false
    @State private var pendingEmoticon: ForumEmoticon?

    var body: some View {
        @Bindable var session = controller.bbcodeSession
        VStack(spacing: 6) {
            if !session.isFullScreen {
                ForumBBCodeEditorSurface(text: $text, controller: controller, composerContext: composerContext, parsesBBCode: parsesBBCode, parsesEmoticons: parsesEmoticons, height: compact ? 220 : 320, onEmoticons: showEmoticons)
            } else { Color.clear.frame(height: compact ? 220 : 320) }
            ForumBBCodeEditorFooter(textCount: text.count, session: session, compact: compact, draftStatus: draftStatus, onDrafts: onDrafts)
        }
        .sheet(item: Binding(get: { session.isFullScreen ? nil : session.nodeRequest }, set: { if !session.isFullScreen { session.nodeRequest = $0 } }), onDismiss: { session.cancelNodeEditing() }) { request in
            ForumComposerNodePanel(request: request, session: session)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showsEmoticons, onDismiss: {
            if let item = pendingEmoticon { _ = session.insertMarkup(item.code); pendingEmoticon = nil }
        }) {
            ForumEmoticonPicker { item in pendingEmoticon = item; showsEmoticons = false }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $session.isFullScreen, onDismiss: { session.commitComposition(resign: true) }) {
            ForumBBCodeFullScreen(text: $text, controller: controller, composerContext: composerContext, parsesBBCode: parsesBBCode, parsesEmoticons: parsesEmoticons)
        }
        .modifier(ForumComposerImagePaste(session: session))
        .alert(L10n.string("common.error"), isPresented: Binding(get: { session.errorMessage != nil && !session.isFullScreen && session.nodeRequest == nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button(L10n.string("common.done")) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }

    private func showEmoticons() { controller.bbcodeSession.commitComposition(resign: true); showsEmoticons = true }
}

private struct ForumBBCodeEditorSurface: View {
    @Binding var text: String
    let controller: ForumEditorController
    let composerContext: ForumComposerContext
    let parsesBBCode: Bool
    let parsesEmoticons: Bool
    var isFullScreen = false
    var height: CGFloat?
    let onEmoticons: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForumBBCodeTextEditor(text: $text, controller: controller, composerContext: composerContext, parsesBBCode: parsesBBCode, parsesEmoticons: parsesEmoticons, isFullScreen: isFullScreen)
                    .frame(height: height)
                    .frame(maxHeight: height == nil ? .infinity : nil)
                if text.isEmpty {
                    Text(L10n.string("forum.native.message_placeholder")).foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            Divider()
            ForumBBCodeToolbar(session: controller.bbcodeSession, onEmoticons: onEmoticons)
        }
    }
}

private struct ForumBBCodeEditorFooter: View {
    let textCount: Int
    let session: ForumBBCodeSession
    let compact: Bool
    let draftStatus: String?
    let onDrafts: (() -> Void)?
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { count; Spacer(minLength: 0); actions }
            VStack(alignment: .leading, spacing: 2) { count; HStack { Spacer(minLength: 0); actions } }
        }
    }
    private var count: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string("forum.native.character_count", textCount)).font(.caption.monospacedDigit())
            if let draftStatus { Text(draftStatus).font(.caption2).accessibilityIdentifier("composer-draft-status") }
        }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var actions: some View {
        HStack(spacing: 0) {
            if let onDrafts { ForumComposerIconButton(symbol: "doc.on.doc", title: L10n.string("forum.composer.drafts"), action: onDrafts) }
            if !compact {
                ForumComposerIconButton(symbol: "arrow.up.left.and.arrow.down.right", title: L10n.string("forum.composer.fullscreen")) {
                    session.commitComposition(resign: true); session.isFullScreen = true
                }
            }
            Toggle(L10n.string("forum.composer.source"), isOn: Binding(get: { session.sourceMode }, set: { session.setSourceMode($0) }))
                .toggleStyle(.switch).font(.subheadline).fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44).accessibilityIdentifier("native-composer-plain-text")
        }
    }
}

struct ForumBBCodeToolbar: View {
    let session: ForumBBCodeSession
    let onEmoticons: () -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForumComposerIconButton(symbol: "face.smiling", title: L10n.string("forum.native.emoticons"), action: onEmoticons)
                    .disabled(session.context.emoticons == .denied).accessibilityIdentifier("native-composer-emoticons")
                ForEach([ForumComposerTag.b, .i, .u], id: \.self) { tag in
                    ForumComposerIconButton(symbol: ForumComposerLabels.symbol(tag), title: ForumComposerLabels.title(tag), selected: session.marks[tag] == .on, mixed: session.marks[tag] == .mixed) { session.format(tag) }
                        .disabled(session.context.capability(for: tag) == .denied)
                }
                Menu {
                    ForEach([ForumComposerTag.s, .sup, .sub], id: \.self) { tag in command(tag) }
                    Divider()
                    ForEach([ForumComposerTag.font, .size, .color, .backcolor], id: \.self) { tag in node(tag) }
                    Divider()
                    Button(L10n.string("forum.composer.remove_format"), systemImage: "textformat.alt") { session.removeFormatting() }
                    Button(L10n.string("forum.composer.remove_link"), systemImage: "link.badge.plus") { session.removeFormatting(linksOnly: true) }
                } label: { menuLabel("textformat", title: "forum.composer.text") }
                Menu {
                    ForEach(ForumComposerAlignment.allCases, id: \.self) { alignment in
                        Button(L10n.string("forum.composer.align." + alignment.rawValue), systemImage: alignment == .left ? "text.alignleft" : alignment == .center ? "text.aligncenter" : "text.alignright") { session.format(.align, parameter: alignment.rawValue) }
                    }
                    Divider()
                    ForEach([ForumComposerTag.p, .lineh], id: \.self) { tag in node(tag) }
                    command(.indent)
                    command(.quote)
                    Divider()
                    ForEach(["", "1", "a", "A"], id: \.self) { type in
                        Button(L10n.string(type.isEmpty ? "forum.composer.list_bullet" : "forum.composer.list_ordered") + (type.isEmpty ? "" : " (" + type + ")"), systemImage: type.isEmpty ? "list.bullet" : "list.number") { session.format(.list, parameter: type) }
                    }
                    Button(L10n.string("forum.composer.list_indent"), systemImage: "increase.indent") { session.indentList(increase: true) }
                    Button(L10n.string("forum.composer.list_outdent"), systemImage: "decrease.indent") { session.indentList(increase: false) }
                } label: { menuLabel("paragraph", title: "forum.composer.paragraph") }
                ForumComposerIconButton(symbol: "link", title: ForumComposerLabels.title(.url)) { session.insertNode(.url) }
                    .disabled(session.context.capability(for: .url) == .denied)
                Menu {
                    ForEach([ForumComposerTag.img, .attach, .attachimg, .table, .ruby, .collapse, .hide, .free, .code, .float, .email], id: \.self) { tag in node(tag) }
                    Button(ForumComposerLabels.title(.hr), systemImage: "minus") { _ = session.insertMarkup("[hr]") }
                        .disabled(session.context.capability(for: .hr) == .denied)
                } label: { menuLabel("plus", title: "forum.composer.insert") }
                Menu {
                    ForEach([ForumComposerTag.audio, .media, .flash, .swf, .fly, .qq, .password, .postbg, .page, .index, .indexEntry, .begin], id: \.self) { tag in node(tag) }
                } label: { menuLabel("ellipsis", title: "forum.composer.advanced") }
                Divider().frame(height: 24).padding(.horizontal, 4)
                ForumComposerIconButton(symbol: "arrow.uturn.backward", title: L10n.string("common.undo")) { session.undo() }.disabled(!session.canUndo)
                ForumComposerIconButton(symbol: "arrow.uturn.forward", title: L10n.string("forum.composer.redo")) { session.redo() }.disabled(!session.canRedo)
            }.font(.system(size: 19)).buttonStyle(.borderless)
        }.scrollIndicators(.hidden)
    }
    private func menuLabel(_ symbol: String, title: String) -> some View {
        Image(systemName: symbol).frame(width: 44, height: 44).accessibilityLabel(L10n.string(title)).help(L10n.string(title))
    }
    private func command(_ tag: ForumComposerTag) -> some View {
        Button(ForumComposerLabels.title(tag), systemImage: ForumComposerLabels.symbol(tag)) { session.format(tag) }.disabled(session.context.capability(for: tag) == .denied)
    }
    private func node(_ tag: ForumComposerTag) -> some View {
        Button { session.insertNode(tag) } label: {
            Label(ForumComposerLabels.title(tag), systemImage: ForumComposerLabels.symbol(tag))
        }.disabled(session.context.capability(for: tag) == .denied)
    }
}

struct ForumBBCodeFullScreen: View {
    @Binding var text: String
    let controller: ForumEditorController
    let composerContext: ForumComposerContext
    let parsesBBCode: Bool
    let parsesEmoticons: Bool
    @State private var showsEmoticons = false
    @State private var pendingEmoticon: ForumEmoticon?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var session = controller.bbcodeSession
        NavigationStack {
            VStack(spacing: 6) {
                ForumBBCodeEditorSurface(text: $text, controller: controller, composerContext: composerContext, parsesBBCode: parsesBBCode, parsesEmoticons: parsesEmoticons, isFullScreen: true, onEmoticons: { session.commitComposition(resign: true); showsEmoticons = true })
                ForumBBCodeEditorFooter(textCount: text.count, session: session, compact: true, draftStatus: nil, onDrafts: nil)
            }
            .padding(.horizontal, 12)
            .navigationTitle(L10n.string("forum.native.message")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("common.done")) { session.commitComposition(resign: true); dismiss() } } }
            .sheet(item: $session.nodeRequest, onDismiss: { session.cancelNodeEditing() }) { ForumComposerNodePanel(request: $0, session: session) }
            .sheet(isPresented: $showsEmoticons, onDismiss: { if let item = pendingEmoticon { _ = session.insertMarkup(item.code); pendingEmoticon = nil } }) {
                ForumEmoticonPicker { pendingEmoticon = $0; showsEmoticons = false }
            }
        }
        .modifier(ForumComposerImagePaste(session: session, isFullScreen: true))
        .alert(L10n.string("common.error"), isPresented: Binding(get: { session.errorMessage != nil && session.nodeRequest == nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button(L10n.string("common.done")) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
}
