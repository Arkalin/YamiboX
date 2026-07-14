import SwiftUI
import YamiboXCore

/// One detected favorite update with read and dismiss actions, rendered in
/// the favorite-updates page.
struct FavoriteUpdateEventRow: View {
    let event: FavoriteUpdateEvent
    let onOpen: () async -> Void
    let onMarkRead: () async -> Void
    let onDismiss: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: event.readAt == nil ? "bell.badge" : "bell")
                    .foregroundStyle(event.readAt == nil ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                    Text(event.summary.displayText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let forumName = event.forumName {
                        Text(forumName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                Text(event.detectedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await onOpen() }
            }

            HStack(spacing: 8) {
                if event.readAt == nil {
                    Button {
                        Task { await onMarkRead() }
                    } label: {
                        Label(L10n.string("favorites.updates.mark_read"), systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await onDismiss() }
                } label: {
                    Label(L10n.string("favorites.updates.dismiss"), systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}
