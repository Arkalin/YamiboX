import SwiftUI
import YamiboXCore

#if canImport(UIKit)
import UIKit
#endif

/// Hierarchy detail of the settings screen: pushed onto its navigation
/// stack (drill-down content, not a self-contained modal task), so it owns
/// no `NavigationStack` or close button of its own.
public struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var updateViewModel: AboutUpdateViewModel

    public init() {
        _updateViewModel = StateObject(wrappedValue: AboutUpdateViewModel())
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                AboutHeaderView()
                    .padding(.top, 32)

                AboutLinksSection(
                    isCheckingForUpdates: updateViewModel.isCheckingForUpdates,
                    checkForUpdates: {
                        Task {
                            await updateViewModel.checkForUpdates()
                        }
                    }
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle(L10n.string("about.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .failureAlert(
            updateViewModel.alert?.title ?? "",
            message: updateViewModel.alert?.message,
            details: updateViewModel.alert?.details,
            offersDetails: updateViewModel.alert?.details != nil,
            isPresented: updateAlertIsPresented
        ) {
            if let downloadURL = updateViewModel.alert?.downloadURL {
                Button(L10n.string("app_update.open_download")) {
                    openURL(downloadURL)
                }
                Button(L10n.string("app_update.copy_source")) {
                    copyToPasteboard(AppUpdateChecker.defaultSourceURL.absoluteString)
                }
            }
            Button(L10n.string("common.ok"), role: .cancel) {}
        }
    }

    private var updateAlertIsPresented: Binding<Bool> {
        .presentation(
            isPresented: { updateViewModel.alert != nil },
            clearOnDismiss: { updateViewModel.alert = nil }
        )
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

private struct AboutLinksSection: View {
    let isCheckingForUpdates: Bool
    let checkForUpdates: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(spacing: 0) {
            AboutExternalLinkRow(
                title: L10n.string("about.github"),
                destination: AppMetadata.githubURL
            )

            Divider()

            NavigationLink {
                SpecialThanksView()
            } label: {
                HStack(spacing: 16) {
                    Text(L10n.string("about.special_thanks"))
                        .font(.title3)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 16)

                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            NavigationLink {
                ChangelogView()
            } label: {
                HStack(spacing: 16) {
                    Text(L10n.string("about.changelog"))
                        .font(.title3)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 16)

                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("about-changelog-link")

            Divider()

            Button(action: checkForUpdates) {
                HStack(spacing: 16) {
                    Text(L10n.string("about.check_update"))
                        .font(.title3)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 16)

                    if isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(appTheme.controlAccent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCheckingForUpdates)
            .accessibilityIdentifier("about-check-update-button")
        }
    }
}

struct AboutExternalLinkRow: View {
    let title: String
    let destination: URL
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(.primary)

                Spacer(minLength: 16)

                Image(systemName: "arrow.up.forward.square")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(appTheme.controlAccent)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct AboutHeaderView: View {
    var body: some View {
        VStack(spacing: 16) {
            AppIconView()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 14, y: 8)

            Text(AppMetadata.displayName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Text(AppMetadata.versionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private enum AppMetadata {
    static let githubURL = URL(string: "https://github.com/Arkalin/YamiboX")!

    static var displayName: String {
        let bundle = Bundle.main
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Yamibo X"
    }

    static var versionText: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (version?, build?) where version != build:
            return L10n.string("about.version_with_build", version, build)
        case let (version?, _):
            return L10n.string("about.version", version)
        case let (_, build?):
            return L10n.string("about.version", build)
        case (nil, nil):
            return L10n.string("about.version", "--")
        }
    }
}

@MainActor
final class AboutUpdateViewModel: ObservableObject {
    typealias CheckForUpdate = @Sendable (URL, String, String) async -> AppUpdateCheckResult

    @Published private(set) var isCheckingForUpdates = false
    @Published var alert: AboutUpdateAlert?

    private let sourceURL: URL
    private let currentBundleIdentifier: String
    private let currentVersion: String
    private let checkForUpdate: @Sendable (URL, String, String) async -> AppUpdateCheckOutcome

    init(
        sourceURL: URL = AppUpdateChecker.defaultSourceURL,
        currentBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        checkForUpdate: CheckForUpdate? = nil
    ) {
        self.sourceURL = sourceURL
        self.currentBundleIdentifier = currentBundleIdentifier
        self.currentVersion = currentVersion
        if let checkForUpdate {
            self.checkForUpdate = { url, bundleIdentifier, version in
                await AppUpdateCheckOutcome(result: checkForUpdate(url, bundleIdentifier, version))
            }
        } else {
            self.checkForUpdate = { url, bundleIdentifier, version in
                await AppUpdateChecker().checkForUpdateWithDetails(
                    sourceURL: url, currentBundleIdentifier: bundleIdentifier, currentVersion: version
                )
            }
        }
    }

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let outcome = await checkForUpdate(sourceURL, currentBundleIdentifier, currentVersion)
        guard !Task.isCancelled, !outcome.isCancelled else { return }
        var nextAlert = AboutUpdateAlert(result: outcome.result)
        if let details = outcome.details { nextAlert.details = details }
        alert = nextAlert
    }
}

struct AboutUpdateAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case upToDate
        case updateAvailable(AppSourceVersion)
        case sourceDoesNotContainCurrentApp
        case failure(String)
    }

    let id = UUID()
    var kind: Kind
    var details: LoadFailureDetails?

    init(result: AppUpdateCheckResult) {
        switch result {
        case .upToDate:
            kind = .upToDate
        case let .updateAvailable(version):
            kind = .updateAvailable(version)
        case .sourceDoesNotContainCurrentApp:
            kind = .sourceDoesNotContainCurrentApp
            details = LoadFailureDetails(message: L10n.string("app_update.error.source_missing"))
        case let .failure(error):
            kind = .failure(error.localizedDescription)
            details = LoadFailureDetails(error: error)
        }
    }

    var title: String {
        switch kind {
        case .upToDate:
            L10n.string("app_update.up_to_date_title")
        case .updateAvailable:
            L10n.string("app_update.available_title")
        case .sourceDoesNotContainCurrentApp, .failure:
            L10n.string("app_update.failed_title")
        }
    }

    var message: String {
        switch kind {
        case .upToDate:
            L10n.string("app_update.up_to_date_message")
        case let .updateAvailable(version):
            version.updateAvailableAlertMessage
        case .sourceDoesNotContainCurrentApp:
            L10n.string("app_update.error.source_missing")
        case let .failure(message):
            message
        }
    }

    var downloadURL: URL? {
        if case let .updateAvailable(version) = kind {
            return version.downloadURL
        }
        return nil
    }

}

private struct AppIconView: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let icon = PlatformAppIcon.load() {
            icon
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(appTheme.controlAccent.gradient)

                Image(systemName: "book.pages.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
            }
        }
    }
}

private enum PlatformAppIcon {
    static func load() -> Image? {
        for name in iconNames {
            #if canImport(UIKit)
            if let image = UIImage(named: name) {
                return Image(uiImage: image)
            }
            #endif
        }
        return nil
    }

    private static var iconNames: [String] {
        var names = ["AppIcon"]

        if let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primaryIcon["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files.reversed())
        }

        return names
    }
}
