import SwiftUI
import YamiboXCore

/// Toolbar button showing the offline-cache queue icon plus its entry count,
/// shared by the manga and novel reader cache sheets. The icon slot is
/// customizable so a caller can attach anchor preferences to the icon itself
/// (the manga sheet positions its queue tip popover off the icon bounds).
struct ReaderCacheQueueToolbarButton<Icon: View>: View {
    let entryCount: Int
    let action: () -> Void
    private let icon: (_ isActive: Bool) -> Icon

    init(
        entryCount: Int,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping (_ isActive: Bool) -> Icon
    ) {
        self.entryCount = entryCount
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon(entryCount > 0)
                Text(verbatim: "\(entryCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minWidth: 12, alignment: .trailing)
            }
            .frame(minWidth: 48, minHeight: 32, alignment: .center)
            .foregroundStyle(entryCount > 0 ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.string("reader.cache_queue_button_accessibility_format", entryCount)
        )
    }
}

extension ReaderCacheQueueToolbarButton where Icon == ReaderCacheDownloadQueueIcon {
    init(entryCount: Int, action: @escaping () -> Void) {
        self.init(entryCount: entryCount, action: action) { isActive in
            ReaderCacheDownloadQueueIcon(isActive: isActive)
        }
    }
}
