import SwiftUI
import YamiboXCore

struct ForumThreadPollVotersRequest: Identifiable, Equatable {
    var optionID: String?

    var id: String {
        optionID ?? ""
    }
}

@MainActor
@Observable
final class ForumThreadPollVotersSheetModel {
    private(set) var selectedOptionID: String?
    private(set) var pageNumber = 1
    private(set) var votersPage: ForumThreadPollVotersPage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let load: (String?, Int) async throws -> ForumThreadPollVotersPage

    init(optionID: String?, load: @escaping (String?, Int) async throws -> ForumThreadPollVotersPage) {
        selectedOptionID = optionID
        self.load = load
    }

    var loadIdentity: String {
        "\(selectedOptionID ?? "")\u{1F}\(pageNumber)"
    }

    var selectedOptionName: String {
        guard let votersPage else {
            return L10n.string("forum.thread.poll_voters")
        }
        let id = selectedOptionID ?? votersPage.selectedOptionID
        return votersPage.pollOptions.first(where: { $0.id == id })?.name
            ?? votersPage.pollOptions.first?.name
            ?? L10n.string("forum.thread.poll_voters")
    }

    func selectOption(_ optionID: String) {
        selectedOptionID = optionID
        pageNumber = 1
    }

    func goToPage(_ page: Int) {
        pageNumber = page
    }

    func loadPage() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            votersPage = try await load(selectedOptionID, pageNumber)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ForumThreadPollVotersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForumThreadPollVotersSheetModel

    let onUserTap: (String, String?) -> Void

    init(
        request: ForumThreadPollVotersRequest,
        load: @escaping (String?, Int) async throws -> ForumThreadPollVotersPage,
        onUserTap: @escaping (String, String?) -> Void
    ) {
        _model = State(wrappedValue: ForumThreadPollVotersSheetModel(optionID: request.optionID, load: load))
        self.onUserTap = onUserTap
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.votersPage == nil {
                    ForumContentLoadingView()
                } else if let errorMessage = model.errorMessage, model.votersPage == nil {
                    ForumContentErrorView(message: errorMessage) {
                        Task {
                            await model.loadPage()
                        }
                    }
                } else if let votersPage = model.votersPage {
                    VStack(alignment: .leading, spacing: 14) {
                        optionMenu(votersPage)

                        if votersPage.voters.isEmpty {
                            Text(L10n.string("forum.thread.poll_voters_empty"))
                                .font(.body)
                                .foregroundStyle(ForumColors.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            ScrollView {
                                LazyVGrid(
                                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                                    alignment: .leading,
                                    spacing: 8
                                ) {
                                    ForEach(votersPage.voters, id: \.self) { voter in
                                        ForumThreadPollVoterButton(user: voter, onUserTap: openUser)
                                    }
                                }
                            }
                        }

                        ForumPageNavigationBar(
                            navigation: votersPage.pageNavigation,
                            currentPage: votersPage.pageNavigation?.currentPage ?? model.pageNumber,
                            goToPage: { page in
                                model.goToPage(page)
                            },
                            hidesOnSinglePage: true
                        )
                    }
                    .padding(16)
                }
            }
            .navigationTitle(L10n.string("forum.thread.poll_voters"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close")) {
                        dismiss()
                    }
                }
            }
            .topRefreshIndicator(isVisible: model.isLoading && model.votersPage != nil)
        }
        .task(id: model.loadIdentity) {
            await model.loadPage()
        }
    }

    @ViewBuilder
    private func optionMenu(_ page: ForumThreadPollVotersPage) -> some View {
        if !page.pollOptions.isEmpty {
            Menu {
                ForEach(page.pollOptions) { option in
                    Button(option.name) {
                        model.selectOption(option.id)
                    }
                }
            } label: {
                HStack {
                    Text(model.selectedOptionName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForumColors.textDark)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ForumColors.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func openUser(uid: String, name: String?) {
        dismiss()
        onUserTap(uid, name)
    }
}

private struct ForumThreadPollVoterButton: View {
    let user: BlogReaderUser
    let onUserTap: (String, String?) -> Void

    var body: some View {
        if let uid = user.uid {
            Button {
                onUserTap(uid, user.name)
            } label: {
                Text(user.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ForumColors.brownPrimary)
            .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text(user.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(ForumColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 11)
                .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
