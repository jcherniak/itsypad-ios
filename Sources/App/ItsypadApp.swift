import SwiftUI

@main
struct ItsypadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tabStore = TabStore.shared
    @StateObject private var settings = SettingsStore.shared

    init() {
        CloudSyncEngine.shared.startIfEnabled()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabStore)
                .environmentObject(settings)
                .preferredColorScheme(colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                tabStore.autoEmptyTrash(days: settings.trashAutoEmptyDays)
                CloudSyncEngine.shared.fetchChanges()
                AutoPasteController.shared.handleAppOpened()
            } else if phase == .background {
                AutoPasteController.shared.dismiss()
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearanceOverride {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
