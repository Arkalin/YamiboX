import SwiftUI
import YamiboXCore

/// The existing filter settings model and rule editor are shared. Only the
/// outer scope chooser needs an inline navigation surface on a trackpad.
struct ReaderRemoteCommentFilterSettings: View {
    @State private var viewModel: SettingsReadingViewModel
    @State private var scope: ChapterCommentFilterScope?
    @State private var isLoaded = false

    init(dependencies: SettingsDependencies) {
        _viewModel = State(initialValue: SettingsReadingViewModel(dependencies: dependencies, activity: SystemSettingsActivity()))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if scope != nil {
                    ReaderRemoteButton(action: { scope = nil }) {
                        Image(systemName: "chevron.backward").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("common.back"))
                }
                Text(scope?.title ?? L10n.string("reader.chapter_comments_filter_settings"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 8)
            .background(.bar)
            Divider()
            if let scope {
                ChapterCommentRulesView(viewModel: viewModel, scope: scope)
            } else {
                Form {
                    ForEach(ChapterCommentFilterScope.allCases, id: \.self) { scope in
                        ReaderRemoteButton(action: { self.scope = scope }) {
                            Label(scope.title, systemImage: "line.3.horizontal.decrease")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .readerRemoteScrollContent()
                    }
                }
                .disabled(!isLoaded || viewModel.isBusy)
            }
        }
        .task {
            viewModel.applyLoadedSettings(await viewModel.settingsStore.load())
            isLoaded = true
        }
    }
}
