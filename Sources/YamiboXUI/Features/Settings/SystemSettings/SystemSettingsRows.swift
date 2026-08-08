import SwiftUI

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
