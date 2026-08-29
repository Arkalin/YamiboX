import SwiftUI
import YamiboXCore

struct SystemSettingsHomePageSelector: View {
    let homePage: AppHomePage
    let isBusy: Bool
    let onSelect: (AppHomePage) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var appTheme

    /// App-theme accents are light in dark mode, so selected controls use a
    /// black foreground there rather than assuming white text is readable.
    private var selectedForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("settings.home_page"))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                ForEach([AppHomePage.forum, .favorites], id: \.self) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: option.systemImageName)
                                .font(.subheadline.weight(.semibold))
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(homePage == option ? selectedForeground : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(homePage == option ? appTheme.controlAccent : Color.secondary.opacity(0.12))
                        )
                        .expandedHitTarget()
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityAddTraits(homePage == option ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SystemSettingsRow: View {
    let title: String
    let value: String?
    let showsChevron: Bool
    let showsChevronAfterValue: Bool
    let titleColor: Color

    init(
        title: String,
        value: String? = nil,
        showsChevron: Bool = true,
        showsChevronAfterValue: Bool = false,
        titleColor: Color = .primary
    ) {
        self.title = title
        self.value = value
        self.showsChevron = showsChevron
        self.showsChevronAfterValue = showsChevronAfterValue
        self.titleColor = titleColor
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(titleColor)

            Spacer(minLength: 0)

            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }

            if showsChevron && (value == nil || showsChevronAfterValue) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
