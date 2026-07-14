import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import YamiboXCore

/// The automatic-check-interval picker, smart-manga-interval picker, and
/// notification toggle, shared between `FavoriteUpdatesPage` (behind the
/// favorites bell) and the Settings > Favorites category page. Both
/// embeddings read/write the same `FavoriteLibrarySettings` fields through
/// their own `FavoriteUpdateMonitor` instance, so this view owns its own
/// load state rather than relying on `@Published` fields the monitor
/// doesn't publish for these.
struct FavoriteUpdateSettingsSection: View {
    @ObservedObject var updateMonitor: FavoriteUpdateMonitor

    @State private var selectedInterval: FavoriteUpdateCheckInterval = .off
    @State private var selectedMangaInterval: SmartMangaUpdateCheckInterval = .threeDays
    @State private var notificationsEnabled = false
    @State private var notificationsBlockedBySystem = false
    @State private var showsNotificationDeniedAlert = false

    var body: some View {
        Group {
            intervalSection
            mangaIntervalSection
            notificationSection
        }
        .task {
            await reload()
        }
        // `.task` only fires once per view identity. This view is embedded
        // in two independently-instantiated `FavoriteUpdateMonitor`-backed
        // screens that can both stay alive at once (a background tab's
        // pushed FavoriteUpdatesPage plus this screen), so a change made
        // through the other instance would otherwise never be reflected
        // here again after the first load — `.onAppear` re-reads on every
        // return to this screen, not just the first.
        .onAppear {
            Task { await reload() }
        }
        .alert(
            L10n.string("favorites.updates.notifications_denied_title"),
            isPresented: $showsNotificationDeniedAlert
        ) {
            #if canImport(UIKit)
            Button(L10n.string("favorites.updates.notifications_open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #endif
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("favorites.updates.notifications_denied_message"))
        }
    }

    private func reload() async {
        selectedInterval = await updateMonitor.configuredInterval() ?? .off
        selectedMangaInterval = await updateMonitor.configuredMangaInterval() ?? .threeDays
        notificationsEnabled = await updateMonitor.notificationsEnabled()
        notificationsBlockedBySystem = await updateMonitor.notificationsBlockedBySystem()
    }

    private var intervalSection: some View {
        Section {
            Picker(L10n.string("favorites.updates.interval"), selection: $selectedInterval) {
                ForEach(FavoriteUpdateCheckInterval.allCases) { interval in
                    Text(interval.title)
                        .tag(interval)
                }
            }
            .onChange(of: selectedInterval) { _, newValue in
                Task { await updateMonitor.setConfiguredInterval(newValue) }
            }
        } footer: {
            Text(L10n.string("favorites.updates.interval_footer"))
        }
    }

    private var mangaIntervalSection: some View {
        Section {
            Picker(L10n.string("favorites.updates.manga_interval"), selection: $selectedMangaInterval) {
                ForEach(SmartMangaUpdateCheckInterval.allCases) { interval in
                    Text(interval.title)
                        .tag(interval)
                }
            }
            .onChange(of: selectedMangaInterval) { _, newValue in
                Task { await updateMonitor.setConfiguredMangaInterval(newValue) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("favorites.updates.manga_interval_footer_read_required"))
                Text(L10n.string("favorites.updates.manga_interval_footer_mode_off"))
            }
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle(L10n.string("favorites.updates.notifications"), isOn: notificationsBinding)
        } footer: {
            if notificationsBlockedBySystem {
                Text(L10n.string("favorites.updates.notifications_blocked"))
            } else {
                Text(L10n.string("favorites.updates.notifications_footer"))
            }
        }
    }

    /// A custom binding (not `onChange`) so reverting a denied enable back to
    /// off doesn't re-enter the setter and re-trigger the alert.
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { requested in
                notificationsEnabled = requested
                Task {
                    let effective = await updateMonitor.setNotificationsEnabled(requested)
                    notificationsEnabled = effective
                    notificationsBlockedBySystem = await updateMonitor.notificationsBlockedBySystem()
                    if requested, !effective {
                        showsNotificationDeniedAlert = true
                    }
                }
            }
        )
    }
}
