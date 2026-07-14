import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit
#endif

enum ReaderLoadStateStatus: Equatable, Sendable {
    case loading
    case failed(title: String = L10n.string("common.load_failed"), message: String)
}

struct ReaderLoadStateView: View {
    let status: ReaderLoadStateStatus
    let retryAction: (() -> Void)?
    let tint: Color

    init(
        status: ReaderLoadStateStatus,
        retryAction: (() -> Void)? = nil,
        tint: Color = .primary
    ) {
        self.status = status
        self.retryAction = retryAction
        self.tint = tint
    }

    var body: some View {
        switch status {
        case .loading:
            ReaderLoadStateLoadingContent(tint: tint)
        case let .failed(title, message):
            ReaderLoadStateFailureContent(
                title: title,
                message: message,
                retryAction: retryAction,
                tint: tint
            )
        }
    }
}

private struct ReaderLoadStateLoadingContent: View {
    let tint: Color

    var body: some View {
        ProgressView(L10n.string("common.loading"))
            .tint(tint)
            .foregroundStyle(tint)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReaderLoadStateFailureContent: View {
    let title: String
    let message: String
    let retryAction: (() -> Void)?
    let tint: Color

    var body: some View {
        VStack(spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)

            if !message.isEmpty {
                Text(message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let retryAction {
                Button(L10n.string("common.retry"), action: retryAction)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            }
        }
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS)
final class ReaderLoadStateOverlayView: UIView {
    private let loadingStack = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private let failureStack = UIStackView()
    private let failureTitleLabel = UILabel()
    private let failureMessageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var retryAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        status: ReaderLoadStateStatus,
        retryAction: (() -> Void)? = nil,
        tintColor: UIColor = .label
    ) {
        self.retryAction = retryAction
        isHidden = false
        updateTint(tintColor)

        switch status {
        case .loading:
            failureStack.isHidden = true
            loadingStack.isHidden = false
            loadingIndicator.startAnimating()
        case let .failed(title, message):
            loadingIndicator.stopAnimating()
            loadingStack.isHidden = true
            failureTitleLabel.text = title
            failureMessageLabel.text = message
            failureMessageLabel.isHidden = message.isEmpty
            retryButton.isHidden = retryAction == nil
            failureStack.isHidden = false
        }
    }

    func hide() {
        retryAction = nil
        loadingIndicator.stopAnimating()
        loadingStack.isHidden = true
        failureStack.isHidden = true
        isHidden = true
    }

    private func configureViewHierarchy() {
        backgroundColor = .clear
        isHidden = true

        loadingLabel.text = L10n.string("common.loading")
        loadingLabel.font = .preferredFont(forTextStyle: .body)
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = 10
        loadingStack.isHidden = true
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.addArrangedSubview(loadingIndicator)
        loadingStack.addArrangedSubview(loadingLabel)
        addSubview(loadingStack)

        failureTitleLabel.font = .preferredFont(forTextStyle: .headline)
        failureTitleLabel.textAlignment = .center
        failureTitleLabel.adjustsFontForContentSizeCategory = true
        failureTitleLabel.numberOfLines = 0
        failureMessageLabel.font = .preferredFont(forTextStyle: .body)
        failureMessageLabel.textAlignment = .center
        failureMessageLabel.adjustsFontForContentSizeCategory = true
        failureMessageLabel.numberOfLines = 0
        retryButton.setTitle(L10n.string("common.retry"), for: .normal)
        retryButton.addTarget(self, action: #selector(handleRetryButtonTap), for: .touchUpInside)
        failureStack.axis = .vertical
        failureStack.alignment = .center
        failureStack.spacing = 12
        failureStack.isHidden = true
        failureStack.translatesAutoresizingMaskIntoConstraints = false
        failureStack.addArrangedSubview(failureTitleLabel)
        failureStack.addArrangedSubview(failureMessageLabel)
        failureStack.addArrangedSubview(retryButton)
        addSubview(failureStack)

        NSLayoutConstraint.activate([
            loadingStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            failureStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            failureStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            failureStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])

        updateTint(.label)
    }

    private func updateTint(_ color: UIColor) {
        tintColor = color
        loadingIndicator.color = color
        loadingLabel.textColor = color
        failureTitleLabel.textColor = color
        failureMessageLabel.textColor = color
        retryButton.tintColor = color
    }

    @objc private func handleRetryButtonTap() {
        retryAction?()
    }
}
#endif
