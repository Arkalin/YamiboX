import SwiftUI
import YamiboXCore

struct PrivateMessageView: View {
    @State private var model: PrivateMessageViewModel

    init(model: PrivateMessageViewModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            PrivateMessageContentView(
                page: model.page,
                currentProfile: model.currentProfile,
                currentPage: model.currentPage,
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                refresh: refresh,
                retry: retry,
                goToPage: goToPage
            )

            Divider()

            PrivateMessageInputBar(
                text: $model.inputText,
                canSend: model.canSend,
                isSending: model.isSending,
                send: send
            )
        }
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await model.refresh()
                    }
                } label: {
                    Label(L10n.string("private_message.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .task {
            await model.load()
        }
        .transientMessage(model.sendResultMessage) {
            model.clearSendResult()
        }
    }

    private func refresh() async {
        await model.refresh()
    }

    private func retry() {
        Task {
            await model.refresh()
        }
    }

    private func goToPage(_ page: Int) {
        Task {
            await model.goToPage(page)
        }
    }

    private func send() {
        Task {
            await model.send()
        }
    }
}

private struct PrivateMessageContentView: View {
    let page: PrivateMessagePage?
    let currentProfile: YamiboProfile?
    let currentPage: Int
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () async -> Void
    let retry: () -> Void
    let goToPage: (Int) -> Void

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if page.messages.isEmpty {
                            PrivateMessageEmptyView()
                        } else {
                            ForEach(page.messages) { message in
                                PrivateMessageBubbleView(message: message, currentProfile: currentProfile)
                            }
                        }
                        ForumPageNavigationBar(
                            navigation: page.pageNavigation,
                            currentPage: currentPage,
                            goToPage: goToPage
                        )
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .refreshable {
                    await refresh()
                }
                .topRefreshIndicator(isVisible: isLoading)
            } else if isLoading {
                ForumContentLoadingView(layout: .fills)
            } else if let errorMessage {
                LoadFailureView(message: errorMessage, retry: retry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                PrivateMessageEmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .forumPageBackground()
    }
}

private struct PrivateMessageBubbleView: View {
    let message: PrivateMessage
    let currentProfile: YamiboProfile?

    private var isMine: Bool {
        message.kind == .me
    }

    private var displayName: String {
        if isMine {
            return currentProfile?.username ?? message.author.name
        }
        return message.author.name
    }

    private var avatarURL: URL? {
        if isMine {
            return currentProfile?.avatarURL ?? message.author.avatarURL
        }
        return message.author.avatarURL
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isMine {
                ForumAvatarView(url: avatarURL, size: 38)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForumColors.secondaryText)
                    .lineLimit(1)

                Text(message.contentText)
                    .font(.subheadline)
                    .foregroundStyle(ForumColors.textDark)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(isMine ? ForumColors.accentFill : ForumColors.creamSurface, in: bubbleShape)
                    .overlay {
                        bubbleShape.stroke(ForumColors.border, lineWidth: 1)
                    }

                if let postedAtText = message.postedAtText {
                    Text(postedAtText)
                        .font(.caption2)
                        .foregroundStyle(ForumColors.brownLight)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)

            if isMine {
                ForumAvatarView(url: avatarURL, size: 38)
            }
        }
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}


private struct PrivateMessageInputBar: View {
    @Binding var text: String
    let canSend: Bool
    let isSending: Bool
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(L10n.string("private_message.input_placeholder"), text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(isSending)

            Button(action: send) {
                if isSending {
                    ProgressView()
                } else {
                    Label(L10n.string("private_message.send"), systemImage: "paperplane.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ForumColors.navBarBackground)
    }
}




private struct PrivateMessageEmptyView: View {
    var body: some View {
        ContentUnavailableView(L10n.string("private_message.empty"), systemImage: "bubble.left")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
    }
}
