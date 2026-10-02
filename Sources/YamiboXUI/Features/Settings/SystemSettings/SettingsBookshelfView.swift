import SwiftUI
import YamiboXCore

struct SettingsBookshelfView: View {
    let viewModel: SettingsBookshelfViewModel

    var body: some View {
        Form {
            Section {
                AppThemeSwitch(
                    L10n.string("settings.bookshelf.only_favorites"),
                    isOn: Binding(
                        get: { viewModel.showsOnlyFavorites },
                        set: { viewModel.updateShowsOnlyFavorites($0) }
                    )
                )
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("settings.bookshelf.only_favorites")
            }

            Section(L10n.string("home.continue")) {
                Picker(L10n.string("settings.bookshelf.continue_mode"), selection: Binding(
                    get: { viewModel.continueSettings.mode },
                    set: { viewModel.updateContinueMode($0) }
                )) {
                    ForEach(BookshelfContinueMode.allCases, id: \.self) { mode in
                        Text(L10n.string("settings.bookshelf.continue_mode.\(mode.rawValue)")).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.bookshelf.continue_mode")

                if viewModel.continueSettings.mode == .separate {
                    Stepper(value: Binding(
                        get: { viewModel.continueSettings.novelCount },
                        set: { viewModel.updateNovelCount($0) }
                    ), in: viewModel.continueSettings.novelCountRange) {
                        countLabel("history.filter.novel", count: viewModel.continueSettings.novelCount)
                    }
                    .accessibilityIdentifier("settings.bookshelf.novel_count")

                    Stepper(value: Binding(
                        get: { viewModel.continueSettings.mangaCount },
                        set: { viewModel.updateMangaCount($0) }
                    ), in: viewModel.continueSettings.mangaCountRange) {
                        countLabel("history.filter.manga", count: viewModel.continueSettings.mangaCount)
                    }
                    .accessibilityIdentifier("settings.bookshelf.manga_count")
                } else {
                    Stepper(value: Binding(
                        get: { viewModel.continueSettings.mixedCount },
                        set: { viewModel.updateMixedCount($0) }
                    ), in: 1...4) {
                        countLabel("settings.bookshelf.continue_count", count: viewModel.continueSettings.mixedCount)
                    }
                    .accessibilityIdentifier("settings.bookshelf.mixed_count")
                }
            }
            .disabled(viewModel.isBusy)
        }
        .navigationTitle(L10n.string("tab.bookshelf"))
        .navigationBarTitleDisplayMode(.inline)
        .failureAlert(
            L10n.string("common.operation_failed"),
            message: viewModel.errorMessage,
            details: viewModel.errorDetails,
            isPresented: .presentation(
                isPresented: { viewModel.errorMessage != nil },
                clearOnDismiss: { viewModel.errorMessage = nil }
            )
        ) {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }
    }

    private func countLabel(_ titleKey: String, count: Int) -> some View {
        HStack {
            Text(L10n.string(titleKey))
            Spacer()
            Text(L10n.string("settings.bookshelf.book_count", count))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
