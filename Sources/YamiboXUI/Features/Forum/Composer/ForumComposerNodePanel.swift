import Observation
import SwiftUI
import UIKit
import YamiboXCore

@MainActor
@Observable
final class ForumComposerNodePanelModel {
    let request: ForumComposerNodeEditRequest
    var body: String
    var value: String
    var width = "640"
    var height = "360"
    var dimensionsEnabled = false
    var alignment = ForumComposerAlignment.left
    var number = 3.0
    var sizeUnit = "legacy"
    var title = ""
    var expanded = false
    var daysEnabled = false
    var creditsEnabled = false
    var days = 7
    var credits = 100
    var lineHeight = 30.0
    var indent = 2.0
    var lineHeightEnabled = true
    var indentEnabled = true
    var effect = 0
    var seconds = 5
    var color = Color.red
    var rawParameters = false
    var rawParameter: String
    var error: String?
    @ObservationIgnored private var initialParameter = ""
    @ObservationIgnored let bodyController = ForumEditorController()

    init(request: ForumComposerNodeEditRequest) {
        self.request = request
        body = request.body
        value = request.parameter
        rawParameter = request.parameter
        switch ForumComposerAttributes.parse(tag: request.tag, parameter: request.parameter) {
        case let .dimensions(dimensions):
            width = dimensions.width.source; height = dimensions.height.source; dimensionsEnabled = true
        case let .alignment(alignment): self.alignment = alignment
        case let .paragraph(paragraph):
            alignment = paragraph.alignment; lineHeight = paragraph.lineHeight ?? 30; indent = paragraph.firstLineIndent ?? 0
            lineHeightEnabled = paragraph.lineHeight != nil; indentEnabled = paragraph.firstLineIndent != nil
        case let .lineHeight(value): number = value
        case let .collapse(expanded, title): self.expanded = expanded; self.title = title
        case let .hide(condition):
            daysEnabled = condition.days != nil; creditsEnabled = condition.credits != nil
            days = condition.days ?? 7; credits = condition.credits ?? 100
        case let .media(type, dimensions):
            value = type
            dimensionsEnabled = dimensions != nil
            if let dimensions { width = dimensions.width.source; height = dimensions.height.source }
        case let .begin(link, dimensions, effect, seconds):
            value = link; width = dimensions.width.source; height = dimensions.height.source
            self.effect = effect; self.seconds = seconds; dimensionsEnabled = true
        default: break
        }
        if request.tag == .size {
            if request.parameter.lowercased().hasSuffix("px") || request.parameter.lowercased().hasSuffix("pt") {
                sizeUnit = String(request.parameter.suffix(2)).lowercased(); number = Double(request.parameter.dropLast(2)) ?? 17
            } else { number = Double(request.parameter) ?? 3 }
        }
        if request.tag == .color || request.tag == .backcolor,
           let hex = ForumComposerSyntax.normalizedColor(request.parameter) {
            color = Self.color(hex)
        }
        initialParameter = generatedParameter
    }

    var parameter: String { rawParameters ? rawParameter : generatedParameter == initialParameter ? request.parameter : generatedParameter }
    private var generatedParameter: String {
        switch request.tag {
        case .size: ForumComposerLength.number(number) + (sizeUnit == "legacy" ? "" : sizeUnit)
        case .align, .float: alignment.rawValue
        case .p: ForumComposerParagraph(lineHeight: lineHeightEnabled ? lineHeight : nil, firstLineIndent: indentEnabled ? indent : nil, alignment: alignment).source
        case .lineh: ForumComposerLength.number(number)
        case .collapse: "\(expanded ? 1 : 0)," + title
        case .hide: ForumComposerHideCondition(days: daysEnabled ? days : nil, credits: creditsEnabled ? credits : nil).source
        case .img, .flash: dimensionsEnabled ? width + "," + height : ""
        case .media: value + (dimensionsEnabled ? "," + width + "," + height : "")
        case .begin: dimensionsEnabled ? [value, width, height, String(effect), String(seconds)].joined(separator: ",") : ""
        default: value
        }
    }
    func setColor(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        value = String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        self.color = color
    }
    static func color(_ hex: String) -> Color {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct ForumComposerNodePanel: View {
    let request: ForumComposerNodeEditRequest
    let session: ForumBBCodeSession
    @State private var model: ForumComposerNodePanelModel?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            if request.tag == .table {
                ForumComposerTablePanel(request: request, session: session)
            } else if let model {
                ForumComposerNodePanelContent(model: model, session: session, onCancel: { dismiss() })
            } else { ProgressView() }
        }
        .task {
            if model == nil, request.tag != .table {
                let created = ForumComposerNodePanelModel(request: request)
                created.bodyController.bbcodeSession.localImages = session.localImages
                created.bodyController.bbcodeSession.refererURL = session.refererURL
                created.bodyController.bbcodeSession.onURLTap = session.onURLTap
                model = created
            }
        }
    }
}

private struct ForumComposerNodePanelContent: View {
    @Bindable var model: ForumComposerNodePanelModel
    let session: ForumBBCodeSession
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            if session.context.capability(for: model.request.tag) == .unknown {
                Section { Label(L10n.string("forum.composer.capability_unknown"), systemImage: "questionmark.circle").font(.footnote).foregroundStyle(.secondary) }
            }
            ForumComposerNodeProperties(model: model, context: session.context)
            ForumComposerNodeBody(model: model, context: session.context)
            if [.url, .email, .img, .audio, .media, .flash, .swf].contains(model.request.tag),
               let url = ForumComposerSyntax.safeURL([.url, .email].contains(model.request.tag) && !model.parameter.isEmpty ? model.parameter : model.body, email: model.request.tag == .email) {
                Section {
                    Button(L10n.string("forum.composer.open_link"), systemImage: "arrow.up.right.square") {
                        if let action = session.onURLTap { action(url) } else { openURL(url) }
                    }
                }
            }
            if !model.request.tag.isSingleton {
                Section(L10n.string("forum.composer.preview")) {
                    ForumComposerStaticPreview(source: (try? ForumComposerSyntax.markup(tag: model.request.tag, parameter: model.parameter, body: model.body)) ?? model.request.originalSource ?? "", context: session.context, localImages: session.localImages)
                        .frame(height: model.request.tag == .ruby ? 70 : 190)
                        .accessibilityIdentifier("composer-node-preview")
                }
            }
            if model.request.tag != .password && model.request.tag != .postbg && !model.request.tag.isSingleton {
                Section {
                    Toggle(L10n.string("forum.composer.raw_parameters"), isOn: $model.rawParameters)
                    if model.rawParameters {
                        TextField(L10n.string("forum.composer.parameters"), text: $model.rawParameter).font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(ForumComposerLabels.title(model.request.tag)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.string("common.cancel"), action: onCancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("common.done")) {
                    model.bodyController.pauseEditing()
                    guard validateBody() else { return }
                    if session.saveNode(model.request, parameter: model.parameter, body: model.body) { dismiss() }
                    else { model.error = session.errorMessage }
                }.accessibilityIdentifier("composer-node-confirm")
            }
        }
        .interactiveDismissDisabled()
    }
    private func validateBody() -> Bool {
        if [.attach, .attachimg].contains(model.request.tag), Int(model.body).map({ $0 > 0 }) != true {
            model.error = L10n.string("forum.composer.invalid_attachment"); return false
        }
        if [.password, .img, .audio, .media, .flash, .swf, .qq].contains(model.request.tag), model.body.isEmpty {
            model.error = L10n.string("forum.composer.value_required"); return false
        }
        return true
    }
}

private struct ForumComposerNodeProperties: View {
    @Bindable var model: ForumComposerNodePanelModel
    let context: ForumComposerContext
    var body: some View {
        Section(L10n.string("forum.composer.properties")) {
            switch model.request.tag {
            case .url, .email:
                TextField(L10n.string("forum.composer.target"), text: $model.value).keyboardType(model.request.tag == .email ? .emailAddress : .URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            case .font:
                TextField(ForumComposerLabels.title(.font), text: $model.value).autocorrectionDisabled()
                Picker(L10n.string("forum.composer.font_presets"), selection: $model.value) {
                    ForEach(Array(Set([model.value, "Arial", "Times New Roman", "Courier New", "宋体", "黑体", "楷体", "微软雅黑"])).sorted(), id: \.self) { Text($0).tag($0) }
                }
            case .size:
                Picker(ForumComposerLabels.title(.size), selection: $model.sizeUnit) {
                    Text(L10n.string("forum.composer.legacy_size")).tag("legacy"); Text("px").tag("px"); Text("pt").tag("pt")
                }.pickerStyle(.segmented)
                Stepper(value: $model.number, in: model.sizeUnit == "legacy" ? 1...7 : 1...128, step: 1) {
                    Text(ForumComposerLength.number(model.number) + (model.sizeUnit == "legacy" ? "" : " " + model.sizeUnit))
                }
            case .color, .backcolor:
                ForumComposerColorField(value: $model.value)
            case .align, .float:
                ForumComposerAlignmentPicker(alignment: $model.alignment, allowsCenter: model.request.tag != .float)
            case .p:
                ForumComposerAlignmentPicker(alignment: $model.alignment)
                Toggle(L10n.string("forum.composer.fixed_line_height"), isOn: $model.lineHeightEnabled)
                if model.lineHeightEnabled { Stepper(L10n.string("forum.composer.line_height_px", Int(model.lineHeight)), value: $model.lineHeight, in: 1...200, step: 1) }
                Toggle(L10n.string("forum.composer.use_first_indent"), isOn: $model.indentEnabled)
                if model.indentEnabled { Stepper(L10n.string("forum.composer.first_indent", Int(model.indent)), value: $model.indent, in: 0...20, step: 1) }
            case .lineh:
                HStack { Text(L10n.string("forum.composer.line_height_multiple")); Spacer(); Text(model.number, format: .number.precision(.fractionLength(1))) }
                Slider(value: $model.number, in: 0.5...5, step: 0.1)
            case .collapse:
                TextField(L10n.string("forum.composer.title"), text: $model.title)
                Toggle(L10n.string("forum.composer.expanded"), isOn: $model.expanded)
            case .hide:
                Toggle(L10n.string("forum.composer.hide_credits"), isOn: $model.creditsEnabled)
                if model.creditsEnabled { Stepper(value: $model.credits, in: 0...1_000_000) { Text(L10n.string("forum.composer.credits", model.credits)) } }
                Toggle(L10n.string("forum.composer.hide_days"), isOn: $model.daysEnabled)
                if model.daysEnabled { Stepper(value: $model.days, in: 0...36_500) { Text(L10n.string("forum.composer.days", model.days)) } }
                if !model.creditsEnabled && !model.daysEnabled { Text(L10n.string("forum.composer.hide_reply")).foregroundStyle(.secondary) }
            case .img, .flash, .media, .begin:
                if model.request.tag == .media {
                    TextField(L10n.string("forum.composer.media_type"), text: $model.value).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                if model.request.tag == .begin { TextField(L10n.string("forum.composer.target"), text: $model.value).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Toggle(L10n.string("forum.composer.dimensions"), isOn: $model.dimensionsEnabled)
                if model.dimensionsEnabled { ForumComposerDimensionFields(width: $model.width, height: $model.height) }
                if model.request.tag == .begin {
                    Picker(L10n.string("forum.composer.effect"), selection: $model.effect) {
                        Text(L10n.string("forum.composer.effect.0")).tag(0); Text(L10n.string("forum.composer.effect.1")).tag(1); Text(L10n.string("forum.composer.effect.2")).tag(2)
                    }
                    Stepper(L10n.string("forum.composer.seconds", model.seconds), value: $model.seconds, in: 0...3600)
                }
            case .audio:
                Toggle(L10n.string("forum.composer.audio_flag"), isOn: Binding(get: { model.value == "1" }, set: { model.value = $0 ? "1" : "" }))
            case .ruby:
                TextField(L10n.string("forum.composer.annotation"), text: $model.value)
            case .postbg:
                Picker(ForumComposerLabels.title(.postbg), selection: $model.body) {
                    Text(L10n.string("forum.composer.choose")).tag("")
                    ForEach(context.backgrounds) { Text($0.name).tag($0.name) }
                }
            case .indexEntry:
                TextField(L10n.string("forum.composer.index_target"), text: $model.value).textInputAutocapitalization(.never).autocorrectionDisabled()
            default: EmptyView()
            }
        }
    }
}

private struct ForumComposerNodeBody: View {
    @Bindable var model: ForumComposerNodePanelModel
    let context: ForumComposerContext
    var body: some View {
        if model.request.tag == .password {
            Section { SecureField(ForumComposerLabels.title(.password), text: $model.body).textInputAutocapitalization(.never).autocorrectionDisabled() }
        } else if model.request.tag == .postbg || model.request.tag.isSingleton && model.request.tag != .indexEntry {
            EmptyView()
        } else if model.request.tag.isLiteralBody || model.request.tag == .indexEntry {
            Section(model.request.tag == .code ? ForumComposerLabels.title(.code) : L10n.string("forum.composer.content")) {
                if [.attach, .attachimg].contains(model.request.tag), !context.attachments.isEmpty {
                    Picker(L10n.string("forum.composer.attachment"), selection: $model.body) {
                        Text(model.body.isEmpty ? L10n.string("forum.composer.choose") : model.body).tag(model.body)
                        ForEach(context.attachments.filter { $0.id != model.body }) { Text($0.name).tag($0.id) }
                    }
                }
                TextEditor(text: $model.body).font(.system(.body, design: .monospaced))
                    .frame(minHeight: model.request.tag == .code ? 220 : 90).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("composer-node-content")
            }
        } else {
            Section(L10n.string("forum.composer.content")) {
                // Type erasure terminates recursive nested-block panel types.
                AnyView(ForumBBCodeEditor(text: $model.body, controller: model.bodyController, composerContext: context.nestedContent, compact: true))
            }
        }
    }
}

struct ForumComposerAlignmentPicker: View {
    @Binding var alignment: ForumComposerAlignment
    var allowsCenter = true
    var body: some View {
        Picker(ForumComposerLabels.title(.align), selection: $alignment) {
            ForEach(ForumComposerAlignment.allCases.filter { allowsCenter || $0 != .center }, id: \.self) { value in
                Image(systemName: value == .left ? "text.alignleft" : value == .center ? "text.aligncenter" : "text.alignright")
                    .accessibilityLabel(L10n.string("forum.composer.align." + value.rawValue)).tag(value)
            }
        }.pickerStyle(.segmented)
    }
}

struct ForumComposerDimensionFields: View {
    @Binding var width: String
    @Binding var height: String
    var body: some View {
        LabeledContent(L10n.string("forum.composer.width")) { TextField("640", text: $width).multilineTextAlignment(.trailing) }
        LabeledContent(L10n.string("forum.composer.height")) { TextField("360", text: $height).multilineTextAlignment(.trailing) }
    }
}

struct ForumComposerColorField: View {
    @Binding var value: String
    private let swatches = ["#000000", "#FFFFFF", "#FF0000", "#FF9900", "#FFFF00", "#008000", "#00BFFF", "#0000FF", "#800080", "#808080"]
    var body: some View {
        ColorPicker(L10n.string("forum.composer.custom_color"), selection: Binding(get: { ForumComposerNodePanelModel.color(ForumComposerSyntax.normalizedColor(value) ?? "#000000") }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            value = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }), supportsOpacity: false)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 2)], spacing: 2) {
            ForEach(swatches, id: \.self) { hex in
                Button { value = hex } label: {
                    Circle().fill(ForumComposerNodePanelModel.color(hex)).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.secondary, lineWidth: value.uppercased() == hex ? 3 : 0.5)).frame(width: 44, height: 44)
                }.buttonStyle(.borderless).accessibilityLabel(hex).accessibilityAddTraits(value.uppercased() == hex ? .isSelected : [])
            }
        }
        TextField("#RRGGBB", text: $value).autocorrectionDisabled().textInputAutocapitalization(.never)
    }
}

struct ForumComposerStaticPreview: UIViewRepresentable {
    let source: String
    let context: ForumComposerContext
    var localImages: [String: UIImage] = [:]
    @Environment(\.forumTheme) private var theme
    @Environment(\.yamiboImagePipeline) private var pipeline
    func makeCoordinator() -> ForumBBCodeSession { ForumBBCodeSession() }
    func makeUIView(context: Context) -> ForumBBCodeTextView {
        let view = ForumBBCodeTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = false; view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: ForumBBCodeTextView, context: Context) {
        context.coordinator.context = self.context
        context.coordinator.theme = theme
        context.coordinator.imagePipeline = pipeline
        context.coordinator.refererURL = self.context.target.editorURL ?? YamiboDomain.baseURL
        context.coordinator.localImages = localImages
        context.coordinator.load(source, force: true)
    }
}
