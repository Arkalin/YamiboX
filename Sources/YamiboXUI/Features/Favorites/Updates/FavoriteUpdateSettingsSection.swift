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
    @State private var hasLoaded = false
    @State private var updatingNotifications = false
    @State private var pendingIntervalWrite: Task<Void, Never>?
    @State private var pendingMangaIntervalWrite: Task<Void, Never>?

    var body: some View {
        Group {
            intervalSection
            mangaIntervalSection
            notificationSection
        }
        .disabled(!hasLoaded)
        .task {
            await reload()
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
        hasLoaded = false
        await pendingIntervalWrite?.value
        await pendingMangaIntervalWrite?.value
        let interval = await updateMonitor.configuredInterval() ?? .off
        let mangaInterval = await updateMonitor.configuredMangaInterval() ?? .threeDays
        let enabled = await updateMonitor.notificationsEnabled()
        let blocked = await updateMonitor.notificationsBlockedBySystem()
        guard !Task.isCancelled else { return }
        selectedInterval = interval
        selectedMangaInterval = mangaInterval
        if !updatingNotifications {
            notificationsEnabled = enabled
            notificationsBlockedBySystem = blocked
        }
        hasLoaded = true
    }

    private var intervalSection: some View {
        Section {
            Picker(L10n.string("favorites.updates.interval"), selection: intervalBinding) {
                ForEach(FavoriteUpdateCheckInterval.allCases) { interval in
                    Text(interval.title)
                        .tag(interval)
                }
            }
        } footer: {
            Text(L10n.string("favorites.updates.interval_footer"))
        }
    }

    private var mangaIntervalSection: some View {
        Section {
            Picker(L10n.string("favorites.updates.manga_interval"), selection: mangaIntervalBinding) {
                ForEach(SmartMangaUpdateCheckInterval.allCases) { interval in
                    Text(interval.title)
                        .tag(interval)
                }
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
                .disabled(updatingNotifications)
        } footer: {
            if notificationsBlockedBySystem {
                Text(L10n.string("favorites.updates.notifications_blocked"))
            } else {
                Text(L10n.string("favorites.updates.notifications_footer"))
            }
        }
    }

    private var intervalBinding: Binding<FavoriteUpdateCheckInterval> {
        Binding(
            get: { selectedInterval },
            set: { interval in
                guard hasLoaded, interval != selectedInterval else { return }
                selectedInterval = interval
                let previousWrite = pendingIntervalWrite
                pendingIntervalWrite = Task {
                    await previousWrite?.value
                    await updateMonitor.setConfiguredInterval(interval)
                }
            }
        )
    }

    private var mangaIntervalBinding: Binding<SmartMangaUpdateCheckInterval> {
        Binding(
            get: { selectedMangaInterval },
            set: { interval in
                guard hasLoaded, interval != selectedMangaInterval else { return }
                selectedMangaInterval = interval
                let previousWrite = pendingMangaIntervalWrite
                pendingMangaIntervalWrite = Task {
                    await previousWrite?.value
                    await updateMonitor.setConfiguredMangaInterval(interval)
                }
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { notificationsEnabled },
            set: { requested in
                guard hasLoaded, !updatingNotifications, requested != notificationsEnabled else { return }
                notificationsEnabled = requested
                updatingNotifications = true
                Task {
                    defer { updatingNotifications = false }
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
