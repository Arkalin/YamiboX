import SwiftUI
import YamiboXCore

extension View {
    func readerTransitionOverlay(isPresented: Bool, title: String, onCancel: @escaping () -> Void) -> some View {
        modifier(ReaderTransitionOverlay(isPresented: isPresented, title: title, onCancel: onCancel))
    }
}

private struct ReaderTransitionOverlay: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsIndicator = false
    let isPresented: Bool
    let title: String
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .disabled(isPresented)
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(showsIndicator ? 0.1 : 0)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                        if showsIndicator {
                            HStack(spacing: 14) {
                                ProgressView()
                                    .controlSize(.regular)
                                    .frame(width: 22, height: 22)
                                Text(title)
                                    .font(.callout.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(action: onCancel) {
                                    Image(systemName: "xmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.string("common.cancel"))
                            }
                            .padding(.leading, 20)
                            .padding(.trailing, 10)
                            .padding(.vertical, 14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
                            .frame(maxWidth: 340)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("reader.transition.progress")
                        }
                    }
                }
            }
            .task(id: isPresented) {
                guard isPresented else { showsIndicator = false; return }
                // Fast cached switches should not flash a loading panel.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.18)) {
                    showsIndicator = true
                }
            }
    }
}
