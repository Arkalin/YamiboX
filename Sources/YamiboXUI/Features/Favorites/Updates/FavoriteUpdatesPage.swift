import SwiftUI
import YamiboXCore

/// Dedicated favorite-updates page behind the favorites toolbar bell:
/// check controls, the automatic interval, notifications, and the detected
/// update events.
struct FavoriteUpdatesPage: View {
    @ObservedObject var updateMonitor: FavoriteUpdateMonitor
    let routes: LocalFavoritesRoutes
    let isEventVisible: (FavoriteUpdateEvent) -> Bool
    let onOpen: (FavoriteUpdateEvent) async -> Void

    @State private var isDismissAllConfirmationPresented = false

    var body: some View {
        List {
            statusSection
            FavoriteUpdateSettingsSection(updateMonitor: updateMonitor)
            eventsSection
        }
        .navigationTitle(L10n.string("favorites.updates.title"))
        .navigationBarTitleDisplayMode(.inline)
        .destructiveConfirmationDialog(
            L10n.string("favorites.updates.dismiss_all_confirm_title"),
            isPresented: $isDismissAllConfirmationPresented,
            actionTitle: L10n.string("favorites.updates.dismiss_all")
        ) {
            Task { await updateMonitor.dismissAllEvents() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    routes.sheet = .updateFilters
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(L10n.string("favorites.updates.filters"))
            }
        }
    }

    private var statusSection: some View {
        Section {
            if let snapshot = updateMonitor.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.status.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    if let progress = snapshot.progress {
                        Text(progress.displayText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let finishedAt = snapshot.finishedAt {
                        Text(L10n.string("favorites.updates.last_checked", LocalFavoriteRelativeDate.string(from: finishedAt)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.string("favorites.updates.run_counts", snapshot.completedCount, snapshot.totalCount, snapshot.detectedCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            if updateMonitor.snapshot?.status == .running {
                Button(role: .destructive) {
                    Task { await updateMonitor.interrupt() }
                } label: {
                    Label(L10n.string("favorites.updates.interrupt"), systemImage: "stop.circle")
                }
            } else {
                Button {
                    // Manual/foreground check: a larger non-tag directory cap
                    // than the background task's is safe here since the user
                    // is actively waiting on this run, not a tight
                    // BGAppRefreshTask execution budget.
                    Task { _ = await updateMonitor.startCheck(nonTagMangaDirectoryCheckCap: 3) }
                } label: {
                    Label(L10n.string("favorites.updates.check"), systemImage: "arrow.clockwise.circle")
                }
            }
        }
    }

    private var visibleEvents: [FavoriteUpdateEvent] {
        updateMonitor.events.filter(isEventVisible)
    }

    @ViewBuilder
    private var eventsSection: some View {
        Section {
            let events = visibleEvents
            if events.isEmpty {
                Text(L10n.string("favorites.updates.no_events"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    FavoriteUpdateEventRow(
                        event: event,
                        onOpen: {
                            await onOpen(event)
                        },
                        onMarkRead: {
                            await updateMonitor.markEventRead(event.id)
                        },
                        onDismiss: {
                            await updateMonitor.dismissEvent(event.id)
                        }
                    )
                }
            }
        } header: {
            HStack {
                Text(L10n.string("favorites.updates.events"))
                Spacer()
                if !visibleEvents.isEmpty {
                    Button(L10n.string("favorites.updates.dismiss_all")) {
                        isDismissAllConfirmationPresented = true
                    }
                    .font(.footnote)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
            }
        }
    }
}

extension FavoriteUpdateRunStatus {
    var displayTitle: String {
        switch self {
        case .running:
            L10n.string("favorites.updates.checking")
        case .interrupted:
            L10n.string("favorites.updates.interrupted")
        case .failed:
            L10n.string("favorites.updates.failed")
        case .completed:
            L10n.string("favorites.updates.completed")
        case .canceled:
            L10n.string("favorites.updates.canceled")
        }
    }
}
