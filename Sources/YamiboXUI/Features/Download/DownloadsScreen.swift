import SwiftUI
import YamiboXCore

/// Both entry directions use one secondary destination. Returning to the
/// initial page pops it instead of recursively pushing another downloads UI.
struct DownloadsScreen: View {
    enum Page { case management, queue }
    let initialPage: Page
    let management: DownloadManagementViewModel
    let queue: DownloadQueueViewModel
    var showsCloseButton = false
    @State private var showsOtherPage = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerRemoteDismiss) private var dismissRemote

    var body: some View {
        page(initialPage, isRoot: true)
            .navigationDestination(isPresented: $showsOtherPage) {
                page(initialPage == .management ? .queue : .management, isRoot: false)
            }
            .task { await queue.load() }
    }

    @ViewBuilder
    private func page(_ page: Page, isRoot: Bool) -> some View {
        Group {
            switch page {
            case .management:
                DownloadManagementView(viewModel: management, queue: queue) {
                    switchPage(fromRoot: isRoot)
                }
            case .queue:
                DownloadQueueScreen(
                    viewModel: queue,
                    openManagement: {
                        switchPage(fromRoot: isRoot)
                    })
            }
        }
        .toolbar {
            if showsCloseButton && isRoot && dismissRemote == nil && !queue.isSelectionMode && !management.isDownloadManagementSelectionMode {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close")) { dismiss() }
                }
            }
        }
        .readerRemoteBack(dismissRemote != nil && !isRoot) { switchPage(fromRoot: false) }
        .navigationBarBackButtonHidden(!isRoot && dismissRemote != nil)
    }

    private func switchPage(fromRoot: Bool) {
        queue.setSelectionMode(false)
        management.setDownloadManagementSelectionMode(false)
        showsOtherPage = fromRoot
    }
}

extension View {
    func readerRemoteBack(_ isPresented: Bool, action: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            if isPresented {
                ReaderRemoteButton(action: action) {
                    Label(L10n.string("common.back"), systemImage: "chevron.backward")
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// List rows share selection semantics, but not the old card decoration.
private struct DownloadListRowModifier: ViewModifier {
    let isSelected: Bool
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .readerRemoteActivate(action)
            } else {
                content
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .readerRemoteScrollContent()
    }
}

extension View {
    func downloadListRow(isSelected: Bool = false, action: (() -> Void)? = nil) -> some View {
        modifier(DownloadListRowModifier(isSelected: isSelected, action: action))
    }
}
