import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import YamiboXCore

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
        .onAppear {
            Task { await reload() }
        }
        .failureAlert(
            L10n.string("favorites.updates.notifications_denied_title"),
            message: L10n.string("favorites.updates.notifications_denied_message"),
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
            AppThemeSwitch(L10n.string("favorites.updates.notifications"), isOn: notificationsBinding)
        } footer: {
            if notificationsBlockedBySystem {
                Text(L10n.string("favorites.updates.notifications_blocked"))
            } else {
                Text(L10n.string("favorites.updates.notifications_footer"))
            }
        }
    }

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
