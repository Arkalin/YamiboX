import SwiftUI
import YamiboXCore

struct SettingsReadingView: View {
    let viewModel: SettingsReadingViewModel

    var body: some View {
        Form {
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
            isPresented: { viewModel.errorMessage != nil },
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
