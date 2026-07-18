import SwiftUI
import YamiboXCore

struct SettingsReadingView: View {
    let viewModel: SettingsReadingViewModel
    @State private var pendingConfirmation: SystemSettingsConfirmation?

    var body: some View {
        Form {
            Section {
                ForEach(boardReaderRows) { row in
                    SystemSettingsBoardReaderRowMenu(
                        row: row,
                        isBusy: viewModel.isBusy,
                        onSelectMode: { mode in
                            viewModel.setBoardReaderMode(mode, forumID: row.forumID, boardName: row.entry.boardName)
                        }
                    )
                }

                Button(role: .destructive) {
                    pendingConfirmation = .restoreBoardReaderDefaults
                } label: {
                    Text(L10n.string("settings.board_reader.restore_default"))
                }
                .disabled(viewModel.isBusy)
            } header: {
                Text(L10n.string("settings.section.board_reader"))
            } footer: {
                Text(L10n.string("settings.board_reader.footer"))
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
        }
        .navigationTitle(L10n.string("settings.section.reading"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.string("common.operation_failed"), isPresented: errorIsPresented, actions: {
            Button(L10n.string("common.ok")) {
                viewModel.errorMessage = nil
            }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
        .destructiveConfirmationAlert(
            item: $pendingConfirmation,
            title: \.title,
            actionTitle: \.buttonTitle,
            message: \.message
        ) { confirmation in
            Task {
                await handleConfirmation(confirmation)
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

    private var boardReaderRows: [SystemSettingsBoardReaderRow] {
        viewModel.boardReader.entries
            .map { SystemSettingsBoardReaderRow(forumID: $0.key, entry: $0.value) }
            .sorted { lhs, rhs in
                switch (Int(lhs.forumID), Int(rhs.forumID)) {
                case let (lhsNumber?, rhsNumber?):
                    lhsNumber < rhsNumber
                case (.some, nil):
                    true
                case (nil, .some):
                    false
                case (nil, nil):
                    lhs.forumID < rhs.forumID
                }
            }
    }

    private func handleConfirmation(_ confirmation: SystemSettingsConfirmation) async {
        guard confirmation == .restoreBoardReaderDefaults else { return }
        viewModel.resetBoardReader()
    }
}

private struct SystemSettingsBoardReaderRow: Identifiable {
    let forumID: String
    let entry: BoardReaderSettings.Entry

    var id: String {
        forumID
    }

    /// The stored name snapshot; the "板块 N" placeholder is presentation-
    /// only and never written back to storage (PRD revision R9).
    var displayName: String {
        entry.boardName ?? L10n.string("settings.board_reader.board_placeholder", forumID)
    }

    var modeLabel: String {
        switch entry.mode {
        case .normal:
            L10n.string("settings.board_reader.mode.normal")
        case .novel:
            L10n.string("settings.board_reader.mode.novel")
        case .manga(smartEnabled: true):
            L10n.string("settings.board_reader.mode.smart_manga")
        case .manga(smartEnabled: false):
            L10n.string("settings.board_reader.mode.manga")
        }
    }
}

private enum SystemSettingsBoardReaderModeOption: Hashable, CaseIterable {
    case normal
    case novel
    case manga

    var title: String {
        switch self {
        case .normal:
            L10n.string("settings.board_reader.mode.normal")
        case .novel:
            L10n.string("settings.board_reader.mode.novel")
        case .manga:
            L10n.string("settings.board_reader.mode.manga")
        }
    }
}

private struct SystemSettingsBoardReaderRowMenu: View {
    let row: SystemSettingsBoardReaderRow
    let isBusy: Bool
    let onSelectMode: (BoardReaderSettings.ReaderMode) -> Void

    var body: some View {
        Menu {
            // 普通 is a first-class mode option here (an explicit `.normal`
            // entry, R12), not a destructive "remove" action — so no
            // destructive button and no menu divider.
            Picker(L10n.string("settings.board_reader.mode"), selection: modeBinding) {
                ForEach(SystemSettingsBoardReaderModeOption.allCases, id: \.self) { option in
                    Text(option.title)
                        .tag(option)
                }
            }

            if case let .manga(smartEnabled) = row.entry.mode {
                Toggle(
                    L10n.string("settings.board_reader.smart_toggle"),
                    isOn: Binding(
                        get: { smartEnabled },
                        set: { onSelectMode(.manga(smartEnabled: $0)) }
                    )
                )
            }
        } label: {
            SystemSettingsRow(
                title: row.displayName,
                value: row.modeLabel,
                showsChevron: false
            )
        }
        .disabled(isBusy)
    }

    private var modeBinding: Binding<SystemSettingsBoardReaderModeOption> {
        Binding(
            get: {
                switch row.entry.mode {
                case .normal:
                    .normal
                case .novel:
                    .novel
                case .manga:
                    .manga
                }
            },
            set: { option in
                switch option {
                case .normal:
                    guard row.entry.mode != .normal else { return }
                    onSelectMode(.normal)
                case .novel:
                    guard row.entry.mode != .novel else { return }
                    onSelectMode(.novel)
                case .manga:
                    if case .manga = row.entry.mode { return }
                    // Newly manga-configured boards default Smart Comic Mode
                    // off (PRD decision #8).
                    onSelectMode(.manga(smartEnabled: false))
                }
            }
        )
    }
}
