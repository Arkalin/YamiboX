import SwiftUI
import YamiboXCore

struct SettingsReadingView: View {
    let viewModel: SettingsReadingViewModel
    let peripheralsViewModel: SettingsPeripheralsViewModel
    var peripheralInput: ReaderPeripheralInputManager?

    var body: some View {
        Form {
            Section {
                Picker(L10n.string("settings.reader_toolbar.style"), selection: Binding(
                    get: { viewModel.readerToolbarStyle.effectiveStyle },
                    set: { viewModel.updateReaderToolbarStyle($0) }
                )) {
                    ForEach(ReaderToolbarStyle.allCases, id: \.self) { style in
                        Text(L10n.string("settings.reader_toolbar.\(style.rawValue)")).tag(style)
                    }
                }
                .disabled(viewModel.isBusy || !ReaderToolbarStyle.supportsLiquidGlass)
                .accessibilityIdentifier("reader-toolbar-style")
            } header: {
                Text(L10n.string("settings.reader_toolbar.title"))
            } footer: {
                if !ReaderToolbarStyle.supportsLiquidGlass {
                    Text(L10n.string("settings.reader_toolbar.unavailable"))
                }
            }
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
            Section(L10n.string("settings.section.novel_download")) {
                Toggle(
                    L10n.string("settings.novel_download.retain_inline_images"),
                    isOn: novelDownloadRetainsInlineImagesBinding
                )
                .disabled(viewModel.isBusy)

                Toggle(
                    L10n.string("settings.novel_download.auto_refresh"),
                    isOn: novelDownloadAutoRefreshBinding
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

    private var novelDownloadRetainsInlineImagesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.novelDownload.retainsInlineImages },
            set: { viewModel.updateNovelDownloadRetainsInlineImages($0) }
        )
    }

    private var novelDownloadAutoRefreshBinding: Binding<Bool> {
        Binding(
            get: { viewModel.novelDownload.isAutoRefreshEnabled },
            set: { viewModel.updateNovelDownloadAutoRefreshEnabled($0) }
        )
    }
}
