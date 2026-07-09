import SwiftUI

@main
struct SANUnlinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = VolumeStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.hasMountedVolumes
                  ? "externaldrive.fill.badge.checkmark"
                  : "externaldrive.badge.xmark")
        }
        .menuBarExtraStyle(.window)
    }
}
