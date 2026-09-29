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
            if showsCloseButton && isRoot && !queue.isSelectionMode && !management.isDownloadManagementSelectionMode {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close")) { dismiss() }
                }
            }
        }
    }

    private func switchPage(fromRoot: Bool) {
        queue.setSelectionMode(false)
        management.setDownloadManagementSelectionMode(false)
        showsOtherPage = fromRoot
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
            } else {
                content
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    func downloadListRow(isSelected: Bool = false, action: (() -> Void)? = nil) -> some View {
        modifier(DownloadListRowModifier(isSelected: isSelected, action: action))
    }
}
