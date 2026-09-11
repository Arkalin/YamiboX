import SwiftUI
import UIKit
import YamiboXCore

struct ChapterCommentRulesView: View {
    let viewModel: SettingsReadingViewModel
    let scope: ChapterCommentFilterScope
    @State private var editingRule: ChapterCommentFilterRule?
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("settings.chapter_comments.enabled"), isOn: Binding(
                    get: { viewModel.chapterComments[scope].isEnabled },
                    set: { viewModel.setCommentFilterEnabled($0, scope: scope) }
                ))
                .accessibilityIdentifier("chapter-comment-filter-enabled")
            }
            Section(L10n.string("settings.chapter_comments.rules")) {
                if viewModel.chapterComments[scope].rules.isEmpty {
                    Text(L10n.string("settings.chapter_comments.no_rules"))
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.chapterComments[scope].rules) { rule in
                    Button { editingRule = rule } label: {
                        HStack(spacing: 12) {
                            Text(rule.pattern)
                                .font(.body.monospaced())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("chapter-comment-rule-\(rule.id)")
                }
                .onDelete { viewModel.deleteCommentRules(at: $0, scope: scope) }
            }
            Section {
                Button(role: .destructive) { confirmsReset = true } label: {
                    Label(L10n.string("settings.chapter_comments.reset"), systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(viewModel.isBusy || viewModel.pendingCommentRuleEdits > 0)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingRule = .init(pattern: "") } label: {
                    Label(L10n.string("settings.chapter_comments.add"), systemImage: "plus")
                }
                .accessibilityIdentifier("chapter-comment-add-rule")
                .disabled(viewModel.isBusy || viewModel.pendingCommentRuleEdits > 0)
            }
        }
        .confirmationDialog(L10n.string("settings.chapter_comments.reset_confirmation"),
                            isPresented: $confirmsReset, titleVisibility: .visible) {
            Button(L10n.string("settings.chapter_comments.reset"), role: .destructive) {
                viewModel.resetCommentRules(scope: scope)
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        }
        .sheet(item: $editingRule, onDismiss: { viewModel.isEditingCommentRule = false }) { rule in
            ChapterCommentRuleEditor(viewModel: viewModel, scope: scope, rule: rule)
        }
        .onChange(of: editingRule) { _, rule in viewModel.isEditingCommentRule = rule != nil }
    }
}

private struct ChapterCommentRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: SettingsReadingViewModel
    let scope: ChapterCommentFilterScope
    let rule: ChapterCommentFilterRule
    @State private var pattern: String
    @State private var testText = ""
    @State private var syntaxError: String?
    @State private var saveError: String?
    @State private var match: ChapterCommentFilterEngine.Match?
    @State private var validatedPattern: String?
    @State private var isSaving = false

    init(viewModel: SettingsReadingViewModel, scope: ChapterCommentFilterScope, rule: ChapterCommentFilterRule) {
        self.viewModel = viewModel
        self.scope = scope
        self.rule = rule
        _pattern = State(initialValue: rule.pattern)
    }

    private var isDuplicate: Bool {
        viewModel.chapterComments[scope].rules.contains { $0.id != rule.id && $0.pattern == pattern }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("settings.chapter_comments.pattern")) {
                    CommentRuleTextInput(text: $pattern, monospaced: true,
                                         label: L10n.string("settings.chapter_comments.pattern"),
                                         identifier: "chapter-comment-pattern")
                        .frame(minHeight: 104)
                    if let error = isDuplicate ? ChapterCommentPatternError.duplicate.errorDescription : syntaxError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section(L10n.string("settings.chapter_comments.test_text")) {
                    CommentRuleTextInput(text: $testText, monospaced: false,
                                         label: L10n.string("settings.chapter_comments.test_text"),
                                         identifier: "chapter-comment-test-text")
                        .frame(minHeight: 104)
                    if let match {
                        Label(matchTitle(match), systemImage: match == .matched ? "checkmark.circle" : "minus.circle")
                            .foregroundStyle(match == .matched ? Color.green : Color.secondary)
                            .accessibilityIdentifier("chapter-comment-match-result")
                    }
                }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L10n.string("settings.chapter_comments.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.save")) { Task { await save() } }
                        .disabled(isSaving || validatedPattern != pattern || syntaxError != nil || isDuplicate)
                        .accessibilityIdentifier("chapter-comment-save-rule")
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .task(id: [pattern, testText]) { await validate() }
        }
    }

    private func validate() async {
        validatedPattern = nil
        match = nil
        syntaxError = nil
        let candidate = pattern
        do {
            let result = try await viewModel.commentFilterEngine.preview(pattern: candidate, text: testText)
            guard !Task.isCancelled, candidate == pattern else { return }
            validatedPattern = candidate
            match = testText.isEmpty ? nil : result
        } catch {
            guard !Task.isCancelled, candidate == pattern else { return }
            syntaxError = pattern.isEmpty ? nil : error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        do {
            let saved = try await viewModel.saveCommentRule(.init(id: rule.id, pattern: pattern), scope: scope)
            if saved { dismiss() }
            else {
                saveError = viewModel.errorMessage ?? L10n.string("common.operation_failed")
                viewModel.errorMessage = nil
            }
        } catch { saveError = error.localizedDescription }
    }

    private func matchTitle(_ match: ChapterCommentFilterEngine.Match) -> String {
        switch match {
        case .matched: L10n.string("settings.chapter_comments.matched")
        case .unmatched: L10n.string("settings.chapter_comments.unmatched")
        case .timedOut: L10n.string("settings.chapter_comments.timed_out")
        }
    }
}

/// UITextView exposes smart punctuation traits unavailable on SwiftUI TextEditor.
private struct CommentRuleTextInput: UIViewRepresentable {
    @Binding var text: String
    let monospaced: Bool
    let label: String
    let identifier: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.adjustsFontForContentSizeCategory = true
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = .init(top: 6, left: 0, bottom: 6, right: 0)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text { view.text = text }
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
            : .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.isEditable = context.environment.isEnabled
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
    }
}
