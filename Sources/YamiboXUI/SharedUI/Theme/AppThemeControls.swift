import SwiftUI

/// Use only for visible switches. Menu toggles must retain their native
/// automatic style so SwiftUI can represent them as checkable menu actions.
struct AppThemeSwitch<Label: View>: View {
    @Environment(\.appTheme) private var theme
    @Binding private var isOn: Bool
    private let label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        _isOn = isOn
        self.label = label()
    }

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .toggleStyle(.switch)
            .tint(theme.switchTint)
    }
}

extension AppThemeSwitch where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

extension View {
    func appProminentButtonStyle(role: ButtonRole? = nil) -> some View {
        modifier(AppProminentButtonModifier(role: role))
    }
}

private struct AppProminentButtonModifier: ViewModifier {
    let role: ButtonRole?
    @Environment(\.forumTheme) private var theme

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            // Text accents can be white in dark mode. Filled controls instead
            // use the palette's surface that is paired with white foregrounds.
            .tint(role == .destructive ? theme.dangerFill : theme.prominentSurface)
            .foregroundStyle(.white)
    }
}
