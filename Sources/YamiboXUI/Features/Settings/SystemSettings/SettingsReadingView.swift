import SwiftUI
import YamiboXCore

struct SettingsReadingView: View {
    let viewModel: SettingsReadingViewModel
    let peripheralsViewModel: SettingsPeripheralsViewModel
    var peripheralInput: ReaderPeripheralInputManager?

    var body: some View {
        Form {
            Section {
                Toggle(
                    L10n.string("settings.reading_progress.save_normal_thread"),
                    isOn: Binding(
                        get: { viewModel.readingProgress.savesNormalThreadProgress },
                        set: { viewModel.updateSavesNormalThreadProgress($0) }
                    )
                )
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("save-normal-thread-progress")
            } header: {
                Text(L10n.string("settings.reading_progress.title"))
            } footer: {
                Text(L10n.string("settings.reading_progress.footer"))
            }
            Section(L10n.string("settings.chapter_comments.title")) {
                ForEach(ChapterCommentFilterScope.allCases, id: \.self) { scope in
                    NavigationLink {
                        ChapterCommentRulesView(viewModel: viewModel, scope: scope)
                    } label: {
                        LabeledContent(scope.title) {
                            Text(viewModel.chapterComments[scope].isEnabled
                                 ? L10n.string("settings.chapter_comments.rule_count", viewModel.chapterComments[scope].rules.count)
                                 : L10n.string("settings.chapter_comments.disabled"))
                        }
                    }
                    .accessibilityIdentifier("chapter-comment-rules-\(scope.rawValue)")
                }
            }
            Section(L10n.string("settings.section.novel_offline_cache")) {
                Toggle(
                    L10n.string("settings.novel_offline_cache.retain_inline_images"),
                    isOn: novelOfflineCacheRetainsInlineImagesBinding
                )
                .disabled(viewModel.isBusy)

                Toggle(
                    L10n.string("settings.novel_offline_cache.auto_refresh"),
                    isOn: novelOfflineCacheAutoRefreshBinding
                )
                .disabled(viewModel.isBusy)
            }
            SettingsPeripheralSections(viewModel: peripheralsViewModel, peripheralInput: peripheralInput)
        }
        .navigationTitle(L10n.string("settings.section.reading"))
        .navigationBarTitleDisplayMode(.inline)
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: errorIsPresented
        ) {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { viewModel.errorMessage != nil && !viewModel.isEditingCommentRule },
            clearOnDismiss: { viewModel.errorMessage = nil }
        )
    }

    private var novelOfflineCacheRetainsInlineImagesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.novelOfflineCache.retainsInlineImages },
            set: { viewModel.updateNovelOfflineCacheRetainsInlineImages($0) }
        )
    }

    private var novelOfflineCacheAutoRefreshBinding: Binding<Bool> {
        Binding(
            get: { viewModel.novelOfflineCache.isAutoRefreshEnabled },
            set: { viewModel.updateNovelOfflineCacheAutoRefreshEnabled($0) }
        )
    }
}
