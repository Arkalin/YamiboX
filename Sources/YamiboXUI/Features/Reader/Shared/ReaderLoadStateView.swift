import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit
#endif

enum ReaderLoadStateStatus: Equatable, Sendable {
    case loading
    case failed(title: String = L10n.string("common.load_failed"), message: String, details: LoadFailureDetails? = nil)
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
        case let .failed(title, message, details):
            ReaderLoadStateFailureContent(
                title: title,
                message: message,
                details: details,
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
    let details: LoadFailureDetails?
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
                Button(action: retryAction) {
                    Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .tint(tint)
                #if os(iOS)
                ReaderFailureDetailsButton(
                    details: details ?? LoadFailureDetails(message: message.isEmpty ? title : message),
                    tint: tint
                )
                .frame(minHeight: 44)
                #else
                LoadFailureDetailsButton(details: details, message: message.isEmpty ? title : message)
                #endif
            }
        }
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS)
// Collection-cell hosting configurations cannot host a SwiftUI sheet's navigation stack.
private struct ReaderFailureDetailsButton: UIViewRepresentable {
    let details: LoadFailureDetails
    let tint: Color

    func makeUIView(context: Context) -> ReaderFailureDetailsSourceButton {
        ReaderFailureDetailsSourceButton(frame: .zero)
    }

    func updateUIView(_ button: ReaderFailureDetailsSourceButton, context: Context) {
        button.details = details
        button.tintColor = UIColor(tint)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReaderFailureDetailsSourceButton, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: size.width, height: max(44, size.height))
    }

    static func dismantleUIView(_ button: ReaderFailureDetailsSourceButton, coordinator: ()) {
        button.details = nil
    }
}

private final class ReaderFailureDetailsSourceButton: UIButton {
    private weak var detailsController: UIViewController?
    var details: LoadFailureDetails? {
        didSet {
            guard oldValue != details else { return }
            detailsController?.dismiss(animated: true)
            detailsController = nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.title = L10n.string("load_failure.details")
        configuration.image = UIImage(systemName: "info.circle")
        configuration.imagePadding = 8
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .preferredFont(forTextStyle: .subheadline)
            return result
        }
        self.configuration = configuration
        accessibilityIdentifier = "load-failure-details"
        addTarget(self, action: #selector(showDetails), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func showDetails() {
        guard let details else { return }
        if let controller = LoadFailureDetailsPresenter.present(details, from: self) {
            detailsController = controller
        }
    }
}

final class ReaderLoadStateOverlayView: UIView {
    private let loadingStack = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private let failureStack = UIStackView()
    private let failureTitleLabel = UILabel()
    private let failureMessageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let detailsButton = UIButton(type: .system)
    private var retryAction: (() -> Void)?
    private weak var presentedDetailsController: UIViewController?
    private var failureDetails: LoadFailureDetails? {
        didSet {
            guard oldValue != failureDetails else { return }
            presentedDetailsController?.dismiss(animated: true)
            presentedDetailsController = nil
        }
    }

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
            self.retryAction = nil
            failureDetails = nil
            failureStack.isHidden = true
            loadingStack.isHidden = false
            loadingIndicator.startAnimating()
        case let .failed(title, message, details):
            loadingIndicator.stopAnimating()
            loadingStack.isHidden = true
            failureTitleLabel.text = title
            failureMessageLabel.text = message
            failureMessageLabel.isHidden = message.isEmpty
            retryButton.isHidden = retryAction == nil
            detailsButton.isHidden = retryAction == nil
            failureDetails = details ?? LoadFailureDetails(message: message.isEmpty ? title : message)
            failureStack.isHidden = false
        }
    }

    func hide() {
        retryAction = nil
        failureDetails = nil
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
        detailsButton.setTitle(L10n.string("load_failure.details"), for: .normal)
        detailsButton.accessibilityIdentifier = "load-failure-details"
        detailsButton.addTarget(self, action: #selector(handleDetailsButtonTap), for: .touchUpInside)
        failureStack.axis = .vertical
        failureStack.alignment = .center
        failureStack.spacing = 12
        failureStack.isHidden = true
        failureStack.translatesAutoresizingMaskIntoConstraints = false
        failureStack.addArrangedSubview(failureTitleLabel)
        failureStack.addArrangedSubview(failureMessageLabel)
        failureStack.addArrangedSubview(retryButton)
        failureStack.addArrangedSubview(detailsButton)
        addSubview(failureStack)

        NSLayoutConstraint.activate([
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            detailsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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
        detailsButton.tintColor = color
    }

    @objc private func handleRetryButtonTap() {
        retryAction?()
    }

    @objc private func handleDetailsButtonTap() {
        guard let failureDetails else { return }
        if let controller = LoadFailureDetailsPresenter.present(failureDetails, from: self) {
            presentedDetailsController = controller
        }
    }
}
#endif
