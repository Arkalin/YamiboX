import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit
#endif

struct LoadFailureDetailsButton: View {
    let details: LoadFailureDetails?
    let message: String
    @State private var presented: PresentedLoadFailure?

    var body: some View {
        Button {
            presented = PresentedLoadFailure(details: details ?? LoadFailureDetails(message: message))
        } label: {
            Label(L10n.string("load_failure.details"), systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .frame(minHeight: 44)
        .accessibilityIdentifier("load-failure-details")
        .sheet(item: $presented) { failure in
            LoadFailureDetailsSheet(details: failure.details)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: details) { presented = nil }
        .onChange(of: message) { presented = nil }
    }
}

struct PresentedLoadFailure: Identifiable {
    let id = UUID()
    let details: LoadFailureDetails
}

struct LoadFailureDetailsSheet: View {
    let details: LoadFailureDetails
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var showsHTML = false
    @State private var copied = false
    @State private var selectedFailure: Int?

    private var displayedDetails: LoadFailureDetails {
        guard let selectedFailure, details.failures.indices.contains(selectedFailure) else { return details }
        return details.failures[selectedFailure].details
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !details.failures.isEmpty {
                    Picker(L10n.string("load_failure.items"), selection: $selectedFailure) {
                        Text(L10n.string("load_failure.summary")).tag(Int?.none)
                        ForEach(details.failures.indices, id: \.self) { index in
                            Text(details.failures[index].title).tag(Optional(index))
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                }
                if displayedDetails.html != nil {
                    Picker(L10n.string("load_failure.title"), selection: $showsHTML) {
                        Text(L10n.string("load_failure.cause")).tag(false)
                        Text(L10n.string("load_failure.html_tab")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }
                if showsHTML {
                    Text(L10n.string("load_failure.html"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                #if os(iOS)
                LoadFailureTextView(
                    text: showsHTML ? displayedDetails.html ?? "" : displayedDetails.diagnosticText,
                    monospaced: showsHTML
                )
                .id(showsHTML)
                #else
                ScrollView {
                    Text(showsHTML ? displayedDetails.html ?? "" : displayedDetails.diagnosticText)
                        .font(showsHTML ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                #endif
            }
            .navigationTitle(L10n.string("load_failure.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if let onClose { onClose() } else { dismiss() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("common.close"))
                    .accessibilityIdentifier("load-failure-close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = showsHTML ? displayedDetails.html : displayedDetails.copyText
                        #endif
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(L10n.string(copied ? "load_failure.copied" : showsHTML ? "load_failure.copy_html" : "load_failure.copy"))
                    .accessibilityIdentifier("load-failure-copy")
                }
            }
            .onChange(of: showsHTML) { copied = false }
            .onChange(of: selectedFailure) {
                showsHTML = false
                copied = false
            }
        }
        .tint(.accentColor)
        .foregroundStyle(.primary)
    }
}

#if os(iOS)
private struct LoadFailureTextView: UIViewRepresentable {
    let text: String
    let monospaced: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.accessibilityIdentifier = "load-failure-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular), compatibleWith: view.traitCollection)
            : .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        if view.text != text { view.text = text }
    }
}

@MainActor
enum LoadFailureDetailsPresenter {
    @discardableResult
    static func present(_ details: LoadFailureDetails, from view: UIView) -> UIViewController? {
        guard view.window != nil else { return nil }
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var presenter = responder as? UIViewController else { return nil }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        guard !(presenter is LoadFailureDetailsHostingController), !presenter.isBeingDismissed else { return nil }
        let controller = LoadFailureDetailsHostingController(rootView: LoadFailureDetailsSheet(details: details))
        controller.rootView = LoadFailureDetailsSheet(details: details, onClose: { [weak controller] in
            controller?.dismiss(animated: true)
        })
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(controller, animated: true)
        return controller
    }
}

private final class LoadFailureDetailsHostingController: UIHostingController<LoadFailureDetailsSheet> {}
#endif
